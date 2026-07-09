import Foundation
import Observation
import ChessKit
import ChessOnline

/// Live state for one online match: connects, queues, mirrors the
/// authoritative server game locally (for SAN, highlights, and legality
/// hints), and survives brief connection drops by resyncing from game_start.
@MainActor
@Observable
final class OnlineGameSession: Identifiable {
    enum Phase: Equatable {
        case connecting
        case queued
        case playing
        case finished(result: Game.Result, reason: Game.EndReason?)
        case failed(String)
    }

    let id = UUID()
    private(set) var phase: Phase = .connecting
    private(set) var game = Game()
    private(set) var playerColor: PieceColor = .white
    private(set) var opponentName = "Opponent"
    private(set) var opponentConnected = true

    private let account: AccountStore
    private var client: OnlineGameClient?
    private var messageLoop: Task<Void, Never>?
    /// Set once the session is done for good (finished/failed/cancelled) so a
    /// dropped socket stops triggering reconnects.
    private var isTerminal = false

    var board: Board { game.board }
    var lastMove: Move? { game.history.last?.move }
    var isPlayerTurn: Bool {
        phase == .playing && !game.isOver && board.sideToMove == playerColor
    }

    init(account: AccountStore = .shared) {
        self.account = account
    }

    func start() {
        messageLoop = Task { await run() }
    }

    /// Tear down deliberately (user cancelled matchmaking or left the screen).
    func cancel() {
        isTerminal = true
        messageLoop?.cancel()
        client?.close()
    }

    func playMove(_ move: Move) {
        guard isPlayerTurn else { return }
        guard let client else { return }
        // The move applies when the server echoes it back; on a local network
        // the round trip is imperceptible and the server stays authoritative.
        Task { try? await client.send(.move(uci: move.uci)) }
    }

    func resign() {
        guard let client, phase == .playing else { return }
        Task { try? await client.send(.resign) }
    }

    // MARK: - Connection loop

    private func run() async {
        var attempts = 0
        while !isTerminal, !Task.isCancelled {
            do {
                let token = try await account.validAccessToken()
                let client = OnlineGameClient(url: ServerConfig.playSocketURL, accessToken: token)
                self.client = client
                client.connect()

                // Ask for a game: the server replies with `queued`, or with
                // `game_start` (resync) if we're already in one.
                try await client.send(.joinQueue)
                attempts = 0

                for await message in client.messages {
                    handle(message)
                    if isTerminal { break }
                }
            } catch {
                // fall through to retry
            }

            guard !isTerminal, !Task.isCancelled else { return }

            // The socket dropped mid-session. Retry a few times, then give up.
            attempts += 1
            if attempts > 5 {
                phase = .failed("Connection to the server was lost.")
                isTerminal = true
                return
            }
            if phase == .playing {
                opponentConnected = false // visually flag the interruption
            }
            try? await Task.sleep(for: .seconds(min(5, attempts)))
        }
    }

    private func handle(_ message: ServerMessage) {
        switch message {
        case .queued:
            phase = .queued

        case .gameStart(let start):
            playerColor = start.yourColor == "black" ? .black : .white
            opponentName = start.opponentName
            opponentConnected = true
            game = (try? Game.from(uciMoves: start.moves)) ?? Game()
            phase = .playing

        case .movePlayed(let uci):
            try? game.play(uci: uci)

        case .gameOver(let result, let reason):
            let gameResult = Game.Result(rawValue: result) ?? .draw
            let endReason = Game.EndReason(rawValue: reason)
            // Mirror the terminal state locally for terminal reasons the
            // board can't infer (resignation, abandonment).
            if !game.isOver {
                game.end(result: gameResult, reason: endReason ?? .abandoned)
            }
            phase = .finished(result: gameResult, reason: endReason)
            isTerminal = true
            client?.close()

        case .opponentStatus(let connected):
            opponentConnected = connected

        case .errorMessage:
            // Server rejected something (e.g. an illegal move race); the
            // authoritative state is unchanged, so there's nothing to do.
            break
        }
    }
}
