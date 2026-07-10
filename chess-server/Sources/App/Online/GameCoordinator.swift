import Vapor
import ChessKit
import ChessOnline

/// Clock parameters applied to one online game.
struct ClockConfig: Sendable {
    /// Seconds each side starts with.
    var initialSeconds: Double
    /// Seconds added to a side's clock after each of its moves.
    var incrementSeconds: Double

    init(initialSeconds: Double, incrementSeconds: Double) {
        self.initialSeconds = initialSeconds
        self.incrementSeconds = incrementSeconds
    }

    init(_ control: TimeControl) {
        self.init(
            initialSeconds: control.initialSeconds,
            incrementSeconds: control.incrementSeconds
        )
    }

    static let standard = ClockConfig(.default)
}

/// Owns all realtime state: the matchmaking queue and live games. The server
/// is authoritative — every move is validated with ChessKit before broadcast,
/// and clocks/timeouts are enforced here. All mutation happens on this actor;
/// sockets are only written to from here.
actor GameCoordinator {
    /// How long a disconnected player has to return before forfeiting.
    static let abandonGracePeriod: Duration = .seconds(60)

    struct Seat {
        let userID: UUID
        let name: String
        let rating: Int
        var socket: WebSocket?
    }

    /// A game in progress. Confined to the actor.
    private final class LiveGame {
        let id = UUID()
        var game = Game()
        var white: Seat
        var black: Seat
        let timeControl: TimeControl
        let clock: ClockConfig
        var abandonTask: Task<Void, Never>?

        // Clock state: the side to move has been burning time since `turnStartedAt`.
        var whiteSeconds: Double
        var blackSeconds: Double
        var turnStartedAt = ContinuousClock.now
        var timeoutTask: Task<Void, Never>?

        /// Color with a live draw offer on the table, if any.
        var drawOfferedBy: PieceColor?

        init(white: Seat, black: Seat, timeControl: TimeControl, clock: ClockConfig) {
            self.white = white
            self.black = black
            self.timeControl = timeControl
            self.clock = clock
            self.whiteSeconds = clock.initialSeconds
            self.blackSeconds = clock.initialSeconds
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

        func remainingSeconds(of color: PieceColor) -> Double {
            color == .white ? whiteSeconds : blackSeconds
        }

        /// Both clocks as of now, charging elapsed turn time to the mover.
        func currentClock() -> ClockState {
            var white = whiteSeconds
            var black = blackSeconds
            if !game.isOver {
                let elapsed = Double(secondsSinceTurnStart())
                if game.sideToMove == .white { white = max(0, white - elapsed) } else { black = max(0, black - elapsed) }
            }
            return ClockState(whiteSeconds: white, blackSeconds: black)
        }

        private func secondsSinceTurnStart() -> Double {
            let elapsed = ContinuousClock.now - turnStartedAt
            return Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
        }

        /// Deducts the mover's elapsed time. Returns false if the flag fell.
        func chargeMover(increment: Double) -> Bool {
            let elapsed = secondsSinceTurnStart()
            if game.sideToMove == .white {
                whiteSeconds -= elapsed
                if whiteSeconds <= 0 { whiteSeconds = 0; return false }
                whiteSeconds += increment
            } else {
                blackSeconds -= elapsed
                if blackSeconds <= 0 { blackSeconds = 0; return false }
                blackSeconds += increment
            }
            turnStartedAt = .now
            return true
        }
    }

    /// A finished game's players, kept around so both can agree to a rematch.
    private struct RematchSlot {
        let whiteID: UUID
        let blackID: UUID
        /// A rematch is played at the same control as the finished game.
        let timeControl: TimeControl
        var requested: Set<UUID> = []

        func opponent(of userID: UUID) -> UUID? {
            if userID == whiteID { return blackID }
            if userID == blackID { return whiteID }
            return nil
        }
    }

    private let app: Application
    /// Test seam: when set, every game uses these clock parameters instead of
    /// its time control's (matchmaking pools are still per-control).
    private let clockOverride: ClockConfig?
    /// One matchmaking pool per time control; players are only paired within
    /// the pool they asked for.
    private var queues: [TimeControl: [Seat]] = [:]
    private var gamesByID: [UUID: LiveGame] = [:]
    private var gameIDByUser: [UUID: UUID] = [:]
    private var socketsByUser: [UUID: WebSocket] = [:]
    /// Keyed by finished game ID; also indexed per player for lookup.
    private var rematchSlots: [UUID: RematchSlot] = [:]
    private var rematchSlotByUser: [UUID: UUID] = [:]

    init(app: Application, clock: ClockConfig? = nil) {
        self.app = app
        self.clockOverride = clock
    }

    private func clockConfig(for control: TimeControl) -> ClockConfig {
        clockOverride ?? ClockConfig(control)
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
        removeFromAllQueues(userID: userID)
        abandonRematch(userID: userID)

        guard let game = activeGame(for: userID) else { return }
        game.setSocket(nil, for: userID)
        send(.opponentStatus(connected: false), to: game.opponentSeat(of: userID)?.socket)

        // Forfeit if the player doesn't come back in time. (The chess clock
        // keeps running regardless and may end the game sooner.)
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
        case .joinQueue(let timeControl):
            await joinQueue(userID: userID, timeControl: timeControl)
        case .leaveQueue:
            removeFromAllQueues(userID: userID)
        case .move(let uci):
            await playMove(uci: uci, from: userID)
        case .resign:
            await resign(userID: userID)
        case .offerDraw:
            offerDraw(userID: userID)
        case .acceptDraw:
            await acceptDraw(userID: userID)
        case .declineDraw:
            declineDraw(userID: userID)
        case .requestRematch:
            await requestRematch(userID: userID)
        case .declineRematch:
            declineRematch(userID: userID)
        }
    }

    /// An explicit "no" to the opponent's pending rematch request: the slot
    /// dies and the requester gets rematch_declined (distinct from
    /// rematch_unavailable, which means the opponent left).
    private func declineRematch(userID: UUID) {
        guard let slotID = rematchSlotByUser[userID], let slot = rematchSlots[slotID],
              let opponentID = slot.opponent(of: userID),
              slot.requested.contains(opponentID)
        else { return }
        dropRematchSlot(slotID)
        send(.rematchDeclined, to: socketsByUser[opponentID])
    }

    // MARK: - Rematch

    private func requestRematch(userID: UUID) async {
        guard let slotID = rematchSlotByUser[userID], var slot = rematchSlots[slotID] else {
            send(.errorMessage("no rematch available"), to: socketsByUser[userID])
            return
        }
        slot.requested.insert(userID)
        rematchSlots[slotID] = slot

        guard let opponentID = slot.opponent(of: userID) else { return }
        if slot.requested.count == 2 {
            dropRematchSlot(slotID)
            // Colors swap; ratings are re-read so the new game uses post-Elo
            // values, and sockets are taken fresh.
            guard let white = await seat(for: slot.blackID),
                  let black = await seat(for: slot.whiteID)
            else {
                send(.errorMessage("rematch opponent unavailable"), to: socketsByUser[userID])
                return
            }
            startGame(white: white, black: black, timeControl: slot.timeControl)
        } else {
            send(.rematchOffered, to: socketsByUser[opponentID])
        }
    }

    /// Removes `userID` from any pending rematch, telling the other player.
    private func abandonRematch(userID: UUID) {
        guard let slotID = rematchSlotByUser[userID], let slot = rematchSlots[slotID] else { return }
        dropRematchSlot(slotID)
        if let opponentID = slot.opponent(of: userID) {
            send(.rematchUnavailable, to: socketsByUser[opponentID])
        }
    }

    private func dropRematchSlot(_ slotID: UUID) {
        guard let slot = rematchSlots.removeValue(forKey: slotID) else { return }
        rematchSlotByUser[slot.whiteID] = nil
        rematchSlotByUser[slot.blackID] = nil
    }

    private func seat(for userID: UUID) async -> Seat? {
        guard let socket = socketsByUser[userID],
              let user = try? await User.find(userID, on: app.db)
        else { return nil }
        return Seat(userID: userID, name: user.displayName, rating: user.rating, socket: socket)
    }

    private func joinQueue(userID: UUID, timeControl: TimeControl) async {
        guard let socket = socketsByUser[userID] else { return }

        // Already in a game: replay its state instead of queueing.
        if let game = activeGame(for: userID) {
            send(gameStartMessage(game, for: userID), to: socket)
            return
        }

        guard let user = try? await User.find(userID, on: app.db) else {
            send(.errorMessage("account not found"), to: socket)
            return
        }

        // Queueing for a new opponent walks away from any pending rematch,
        // and re-queueing (possibly at another control) replaces the old entry.
        abandonRematch(userID: userID)
        removeFromAllQueues(userID: userID)
        let seat = Seat(userID: userID, name: user.displayName, rating: user.rating, socket: socket)

        // Only pair players who asked for the same time control.
        if var pool = queues[timeControl], !pool.isEmpty {
            let opponent = pool.removeFirst()
            queues[timeControl] = pool
            // Random colors: fair over time and resistant to queue sniping.
            if Bool.random() {
                startGame(white: opponent, black: seat, timeControl: timeControl)
            } else {
                startGame(white: seat, black: opponent, timeControl: timeControl)
            }
        } else {
            queues[timeControl, default: []].append(seat)
            send(.queued, to: socket)
        }
    }

    private func removeFromAllQueues(userID: UUID) {
        for control in queues.keys {
            queues[control]?.removeAll { $0.userID == userID }
        }
    }

    private func startGame(white: Seat, black: Seat, timeControl: TimeControl) {
        let game = LiveGame(
            white: white,
            black: black,
            timeControl: timeControl,
            clock: clockConfig(for: timeControl)
        )
        gamesByID[game.id] = game
        gameIDByUser[white.userID] = game.id
        gameIDByUser[black.userID] = game.id
        send(gameStartMessage(game, for: white.userID), to: white.socket)
        send(gameStartMessage(game, for: black.userID), to: black.socket)
        game.turnStartedAt = .now
        scheduleTimeout(for: game)
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

        // Charge thinking time before validating: a move that arrives after
        // the flag fell loses on time even if the timeout task hasn't fired.
        guard game.chargeMover(increment: game.clock.incrementSeconds) else {
            await flagFell(game)
            return
        }

        do {
            try game.game.play(uci: uci)
        } catch {
            send(.errorMessage("illegal move"), to: socket)
            return
        }

        // Any move sweeps a pending draw offer off the table.
        game.drawOfferedBy = nil

        broadcast(.movePlayed(uci: uci, clock: game.currentClock()), in: game)
        if game.game.isOver {
            await finish(game)
        } else {
            scheduleTimeout(for: game)
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

    // MARK: - Draw offers

    private func offerDraw(userID: UUID) {
        guard let game = activeGame(for: userID), let color = game.color(of: userID),
              !game.game.isOver
        else { return }
        guard game.drawOfferedBy != color else { return } // already pending
        game.drawOfferedBy = color
        send(.drawOffered, to: game.opponentSeat(of: userID)?.socket)
    }

    private func acceptDraw(userID: UUID) async {
        guard let game = activeGame(for: userID), let color = game.color(of: userID),
              !game.game.isOver,
              let pending = game.drawOfferedBy, pending == color.opposite
        else { return }
        game.game.end(result: .draw, reason: .drawAgreement)
        await finish(game)
    }

    private func declineDraw(userID: UUID) {
        guard let game = activeGame(for: userID), let color = game.color(of: userID),
              let pending = game.drawOfferedBy, pending == color.opposite
        else { return }
        game.drawOfferedBy = nil
        send(.drawDeclined, to: game.opponentSeat(of: userID)?.socket)
    }

    // MARK: - Clocks

    private func scheduleTimeout(for game: LiveGame) {
        game.timeoutTask?.cancel()
        guard !game.game.isOver else { return }
        let side = game.game.sideToMove
        let remaining = game.remainingSeconds(of: side)
        let gameID = game.id
        let moveCount = game.game.moveCount
        game.timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining) + .milliseconds(50))
            guard !Task.isCancelled else { return }
            await self?.timeoutIfStillWaiting(gameID: gameID, side: side, moveCount: moveCount)
        }
    }

    private func timeoutIfStillWaiting(gameID: UUID, side: PieceColor, moveCount: Int) async {
        guard let game = gamesByID[gameID], !game.game.isOver else { return }
        // Only if the same side is still to move on the same position.
        guard game.game.sideToMove == side, game.game.moveCount == moveCount else { return }
        if side == .white { game.whiteSeconds = 0 } else { game.blackSeconds = 0 }
        await flagFell(game)
    }

    private func flagFell(_ game: LiveGame) async {
        guard !game.game.isOver else { return }
        let loser = game.game.sideToMove
        game.game.end(
            result: loser == .white ? .blackWins : .whiteWins,
            reason: .timeout
        )
        await finish(game)
    }

    // MARK: - Game teardown

    private func finish(_ game: LiveGame) async {
        game.abandonTask?.cancel()
        game.timeoutTask?.cancel()
        gamesByID[game.id] = nil
        gameIDByUser[game.white.userID] = nil
        gameIDByUser[game.black.userID] = nil

        // Open the rematch window (replacing any stale slots).
        abandonRematch(userID: game.white.userID)
        abandonRematch(userID: game.black.userID)
        rematchSlots[game.id] = RematchSlot(
            whiteID: game.white.userID,
            blackID: game.black.userID,
            timeControl: game.timeControl
        )
        rematchSlotByUser[game.white.userID] = game.id
        rematchSlotByUser[game.black.userID] = game.id

        let ratingDeltas = await updateRatings(for: game)

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
            .gameOver(.init(
                result: game.game.result.rawValue,
                reason: game.game.endReason?.rawValue ?? "",
                ratingDeltaWhite: ratingDeltas?.white,
                ratingDeltaBlack: ratingDeltas?.black
            )),
            in: game
        )
    }

    /// Applies Elo to both players. Every finished game is rated.
    private func updateRatings(for game: LiveGame) async -> (white: Int, black: Int)? {
        let whiteScore: Double
        switch game.game.result {
        case .whiteWins: whiteScore = 1
        case .blackWins: whiteScore = 0
        case .draw: whiteScore = 0.5
        case .ongoing: return nil
        }

        let whiteDelta = Elo.delta(rating: game.white.rating, opponent: game.black.rating, score: whiteScore)
        let blackDelta = Elo.delta(rating: game.black.rating, opponent: game.white.rating, score: 1 - whiteScore)

        do {
            if let white = try await User.find(game.white.userID, on: app.db) {
                white.rating += whiteDelta
                try await white.save(on: app.db)
            }
            if let black = try await User.find(game.black.userID, on: app.db) {
                black.rating += blackDelta
                try await black.save(on: app.db)
            }
        } catch {
            app.logger.error("failed to update ratings for game \(game.id): \(error)")
        }
        return (whiteDelta, blackDelta)
    }

    // MARK: - Helpers

    private func activeGame(for userID: UUID) -> LiveGame? {
        gameIDByUser[userID].flatMap { gamesByID[$0] }
    }

    private func gameStartMessage(_ game: LiveGame, for userID: UUID) -> ServerMessage {
        let color = game.color(of: userID) ?? .white
        let opponent = game.opponentSeat(of: userID)
        return .gameStart(ServerMessage.GameStart(
            gameID: game.id,
            yourColor: color.rawValue,
            opponentName: opponent?.name ?? "Opponent",
            opponentRating: opponent?.rating,
            moves: game.game.uciMoves,
            clock: game.currentClock(),
            timeControl: game.timeControl
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
