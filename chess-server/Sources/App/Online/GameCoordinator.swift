import Vapor
import ChessKit
import ChessOnline

/// Owns all realtime state: the matchmaking queue and live games. The server
/// is authoritative — every move is validated with ChessKit before broadcast.
/// All mutation happens on this actor; sockets are only written to from here.
actor GameCoordinator {
    /// How long a disconnected player has to return before forfeiting.
    static let abandonGracePeriod: Duration = .seconds(60)

    struct Seat {
        let userID: UUID
        let name: String
        var socket: WebSocket?
    }

    /// A game in progress. Confined to the actor.
    private final class LiveGame {
        let id = UUID()
        var game = Game()
        var white: Seat
        var black: Seat
        var abandonTask: Task<Void, Never>?

        init(white: Seat, black: Seat) {
            self.white = white
            self.black = black
        }

        func seat(of userID: UUID) -> Seat? {
            if white.userID == userID { return white }
            if black.userID == userID { return black }
            return nil
        }

        func color(of userID: UUID) -> PieceColor? {
            if white.userID == userID { return .white }
            if black.userID == userID { return .black }
            return nil
        }

        func opponentSeat(of userID: UUID) -> Seat? {
            if white.userID == userID { return black }
            if black.userID == userID { return white }
            return nil
        }

        func setSocket(_ socket: WebSocket?, for userID: UUID) {
            if white.userID == userID { white.socket = socket }
            if black.userID == userID { black.socket = socket }
        }
    }

    private let app: Application
    private var queue: [Seat] = []
    private var gamesByID: [UUID: LiveGame] = [:]
    private var gameIDByUser: [UUID: UUID] = [:]
    private var socketsByUser: [UUID: WebSocket] = [:]

    init(app: Application) {
        self.app = app
    }

    // MARK: - Connection lifecycle

    func connect(userID: UUID, socket: WebSocket) async {
        // One live socket per user: a new connection supersedes the old one.
        if let previous = socketsByUser[userID] {
            try? await previous.close(code: .policyViolation)
        }
        socketsByUser[userID] = socket

        // Reconnect to a game in progress, if any.
        if let game = activeGame(for: userID) {
            game.setSocket(socket, for: userID)
            game.abandonTask?.cancel()
            game.abandonTask = nil
            send(gameStartMessage(game, for: userID), to: socket)
            send(.opponentStatus(connected: game.opponentSeat(of: userID)?.socket != nil), to: socket)
            send(.opponentStatus(connected: true), to: game.opponentSeat(of: userID)?.socket)
        }
    }

    func disconnect(userID: UUID, socket: WebSocket) {
        // Ignore close events from a superseded socket.
        guard socketsByUser[userID] === socket else { return }
        socketsByUser[userID] = nil
        queue.removeAll { $0.userID == userID }

        guard let game = activeGame(for: userID) else { return }
        game.setSocket(nil, for: userID)
        send(.opponentStatus(connected: false), to: game.opponentSeat(of: userID)?.socket)

        // Forfeit if the player doesn't come back in time.
        let gameID = game.id
        game.abandonTask = Task { [weak self] in
            try? await Task.sleep(for: Self.abandonGracePeriod)
            guard !Task.isCancelled else { return }
            await self?.forfeitIfStillGone(gameID: gameID, userID: userID)
        }
    }

    private func forfeitIfStillGone(gameID: UUID, userID: UUID) async {
        guard let game = gamesByID[gameID], !game.game.isOver else { return }
        guard game.seat(of: userID)?.socket == nil else { return }
        let winner = game.color(of: userID)?.opposite ?? .white
        game.game.end(result: winner == .white ? .whiteWins : .blackWins, reason: .abandoned)
        await finish(game)
    }

    // MARK: - Message handling

    func handle(_ message: ClientMessage, from userID: UUID) async {
        switch message {
        case .joinQueue:
            await joinQueue(userID: userID)
        case .leaveQueue:
            queue.removeAll { $0.userID == userID }
        case .move(let uci):
            await playMove(uci: uci, from: userID)
        case .resign:
            await resign(userID: userID)
        }
    }

    private func joinQueue(userID: UUID) async {
        guard let socket = socketsByUser[userID] else { return }

        // Already in a game: replay its state instead of queueing.
        if let game = activeGame(for: userID) {
            send(gameStartMessage(game, for: userID), to: socket)
            return
        }

        guard let name = await displayName(for: userID) else {
            send(.errorMessage("account not found"), to: socket)
            return
        }

        queue.removeAll { $0.userID == userID }
        let seat = Seat(userID: userID, name: name, socket: socket)

        if let opponent = queue.first {
            queue.removeFirst()
            startGame(white: opponent, black: seat)
        } else {
            queue.append(seat)
            send(.queued, to: socket)
        }
    }

    private func startGame(white: Seat, black: Seat) {
        let game = LiveGame(white: white, black: black)
        gamesByID[game.id] = game
        gameIDByUser[white.userID] = game.id
        gameIDByUser[black.userID] = game.id
        send(gameStartMessage(game, for: white.userID), to: white.socket)
        send(gameStartMessage(game, for: black.userID), to: black.socket)
    }

    private func playMove(uci: String, from userID: UUID) async {
        guard let socket = socketsByUser[userID] else { return }
        guard let game = activeGame(for: userID), let color = game.color(of: userID) else {
            send(.errorMessage("no active game"), to: socket)
            return
        }
        guard game.game.sideToMove == color else {
            send(.errorMessage("not your turn"), to: socket)
            return
        }
        do {
            try game.game.play(uci: uci)
        } catch {
            send(.errorMessage("illegal move"), to: socket)
            return
        }

        broadcast(.movePlayed(uci: uci), in: game)
        if game.game.isOver {
            await finish(game)
        }
    }

    private func resign(userID: UUID) async {
        guard let game = activeGame(for: userID), let color = game.color(of: userID) else { return }
        guard !game.game.isOver else { return }
        game.game.end(
            result: color == .white ? .blackWins : .whiteWins,
            reason: .resignation
        )
        await finish(game)
    }

    // MARK: - Game teardown

    private func finish(_ game: LiveGame) async {
        game.abandonTask?.cancel()
        gamesByID[game.id] = nil
        gameIDByUser[game.white.userID] = nil
        gameIDByUser[game.black.userID] = nil

        // Persist before announcing: clients fetch history as soon as they
        // see game_over, and must find the record there.
        let record = GameRecord(
            whiteID: game.white.userID,
            blackID: game.black.userID,
            whiteName: game.white.name,
            blackName: game.black.name,
            result: game.game.result.rawValue,
            endReason: game.game.endReason?.rawValue ?? "",
            uciMoves: game.game.uciMoves.joined(separator: " ")
        )
        do {
            try await record.save(on: app.db)
        } catch {
            app.logger.error("failed to persist game \(game.id): \(error)")
        }

        broadcast(
            .gameOver(
                result: game.game.result.rawValue,
                reason: game.game.endReason?.rawValue ?? ""
            ),
            in: game
        )
    }

    // MARK: - Helpers

    private func activeGame(for userID: UUID) -> LiveGame? {
        gameIDByUser[userID].flatMap { gamesByID[$0] }
    }

    private func gameStartMessage(_ game: LiveGame, for userID: UUID) -> ServerMessage {
        let color = game.color(of: userID) ?? .white
        return .gameStart(ServerMessage.GameStart(
            gameID: game.id,
            yourColor: color.rawValue,
            opponentName: game.opponentSeat(of: userID)?.name ?? "Opponent",
            moves: game.game.uciMoves
        ))
    }

    private func broadcast(_ message: ServerMessage, in game: LiveGame) {
        send(message, to: game.white.socket)
        send(message, to: game.black.socket)
    }

    private func send(_ message: ServerMessage, to socket: WebSocket?) {
        guard let socket else { return }
        guard let text = try? message.jsonString() else { return }
        socket.send(text, promise: nil)
    }

    private func displayName(for userID: UUID) async -> String? {
        (try? await User.find(userID, on: app.db))?.displayName
    }
}

extension Application {
    private struct GameCoordinatorKey: StorageKey {
        typealias Value = GameCoordinator
    }

    var gameCoordinator: GameCoordinator {
        get {
            guard let coordinator = storage[GameCoordinatorKey.self] else {
                fatalError("GameCoordinator not configured")
            }
            return coordinator
        }
        set { storage[GameCoordinatorKey.self] = newValue }
    }
}
