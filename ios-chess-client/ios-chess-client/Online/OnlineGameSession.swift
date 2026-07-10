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
    /// The control chosen in the lobby; games are matched within it. Kept in
    /// sync with the server's game_start echo (a resync is authoritative).
    private(set) var timeControl: TimeControl
    private(set) var playerColor: PieceColor = .white
    private(set) var opponentName = String(localized: "Opponent", comment: "Fallback name shown until the opponent's real name arrives")
    private(set) var opponentRating: Int?
    private(set) var opponentConnected = true

    /// Server-reported clock and when we received it; the active side's
    /// display ticks down locally from this reference point.
    private(set) var clock: ClockState?
    private(set) var clockSyncedAt = Date()

    private(set) var incomingDrawOffer = false
    private(set) var outgoingDrawOffer = false
    /// The player's own Elo change, once the game is over.
    private(set) var ratingDelta: Int?

    // Rematch state (valid while phase is .finished).
    private(set) var rematchRequested = false
    private(set) var rematchOfferedByOpponent = false
    private(set) var rematchDeclined = false
    private(set) var rematchUnavailable = false

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

    init(timeControl: TimeControl = .default, account: AccountStore? = nil) {
        self.timeControl = timeControl
        // Resolve the default inside the main-actor init body rather than as a
        // default argument, which would evaluate `.shared` in a nonisolated
        // context (a hard error under the Swift 6 language mode).
        self.account = account ?? .shared
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

    func offerDraw() {
        guard let client, phase == .playing, !outgoingDrawOffer else { return }
        outgoingDrawOffer = true
        Task { try? await client.send(.offerDraw) }
    }

    func respondToDrawOffer(accept: Bool) {
        guard let client, incomingDrawOffer else { return }
        incomingDrawOffer = false
        Task { try? await client.send(accept ? .acceptDraw : .declineDraw) }
    }

    /// Ask to play the same opponent again. The rematch starts (a fresh
    /// game_start arrives, colors swapped) once both players have asked.
    func requestRematch() {
        guard let client, case .finished = phase, !rematchUnavailable, !rematchRequested else { return }
        rematchRequested = true
        Task { try? await client.send(.requestRematch) }
    }

    /// Decline the opponent's rematch offer.
    func declineRematch() {
        guard let client, rematchOfferedByOpponent, !rematchDeclined else { return }
        rematchDeclined = true
        rematchOfferedByOpponent = false
        Task { try? await client.send(.declineRematch) }
    }

    /// Remaining seconds for `color` as displayed at `date` (the active side
    /// ticks down between server updates), or nil before the game starts.
    func remainingSeconds(for color: PieceColor, at date: Date) -> Double? {
        guard let clock else { return nil }
        var value = color == .white ? clock.whiteSeconds : clock.blackSeconds
        if phase == .playing, !game.isOver, board.sideToMove == color {
            value -= date.timeIntervalSince(clockSyncedAt)
        }
        return max(0, value)
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

                // Ask for a game at the chosen control: the server replies
                // with `queued`, or with `game_start` (resync) if we're
                // already in one.
                try await client.send(.joinQueue(timeControl: timeControl))
                attempts = 0

                for await message in client.messages {
                    handle(message)
                    if isTerminal { break }
                }
            } catch {
                // fall through to retry
            }

            guard !isTerminal, !Task.isCancelled else { return }

            // After a finished game the socket only serves the rematch
            // handshake — if it drops, the rematch is simply off; never
            // reconnect (that would re-queue the player).
            if case .finished = phase {
                rematchUnavailable = true
                return
            }

            // The socket dropped mid-session. Retry a few times, then give up.
            attempts += 1
            if attempts > 5 {
                phase = .failed(String(localized: "Connection to the server was lost.",
                                       comment: "Shown when the game's WebSocket drops"))
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
            // Queued means the server has no game for us: drop any stale
            // resume hint (e.g. a game that ended while the app was closed).
            ActiveGameStore.shared.clear()

        case .gameStart(let start):
            playerColor = start.yourColor == "black" ? .black : .white
            if let control = start.timeControl {
                timeControl = control // e.g. a rematch resync after reconnect
            }
            opponentName = start.opponentName
            opponentRating = start.opponentRating
            opponentConnected = true
            game = (try? Game.from(uciMoves: start.moves)) ?? Game()
            clock = start.clock
            clockSyncedAt = Date()
            // Fresh game (first match or an accepted rematch): clear per-game state.
            incomingDrawOffer = false
            outgoingDrawOffer = false
            ratingDelta = nil
            rematchRequested = false
            rematchOfferedByOpponent = false
            rematchDeclined = false
            rematchUnavailable = false
            phase = .playing
            // A live game exists: let the home screen offer to resume it.
            ActiveGameStore.shared.begin(opponent: start.opponentName)

        case .movePlayed(let uci, let newClock):
            if let move = Move(uci: uci) {
                SoundPlayer.playMove(move, on: board)
            }
            _ = try? game.play(uci: uci) // server is authoritative; ignore local apply failures
            if let newClock {
                clock = newClock
                clockSyncedAt = Date()
            }
            // Any move sweeps draw offers off the table (mirrors the server).
            incomingDrawOffer = false
            outgoingDrawOffer = false

        case .gameOver(let over):
            let gameResult = Game.Result(rawValue: over.result) ?? .draw
            let endReason = Game.EndReason(rawValue: over.reason)
            // Mirror the terminal state locally for terminal reasons the
            // board can't infer (resignation, timeout, abandonment).
            if !game.isOver {
                game.end(result: gameResult, reason: endReason ?? .abandoned)
            }
            ratingDelta = playerColor == .white ? over.ratingDeltaWhite : over.ratingDeltaBlack
            if let delta = ratingDelta {
                account.applyRatingDelta(delta)
            }
            SoundPlayer.play(.gameEnd)
            // The socket stays open: the rematch handshake happens on it, and
            // a fresh game_start flips the session back to .playing.
            phase = .finished(result: gameResult, reason: endReason)
            // The game is over: nothing to resume from the home screen.
            ActiveGameStore.shared.clear()

        case .drawOffered:
            incomingDrawOffer = true

        case .drawDeclined:
            outgoingDrawOffer = false

        case .opponentStatus(let connected):
            opponentConnected = connected

        case .rematchOffered:
            rematchOfferedByOpponent = true

        case .rematchDeclined:
            rematchRequested = false

        case .rematchUnavailable:
            rematchUnavailable = true
            rematchOfferedByOpponent = false

        case .errorMessage:
            // Server rejected something (e.g. an illegal move race); the
            // authoritative state is unchanged, so there's nothing to do.
            break
        }
    }
}
