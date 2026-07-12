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

/// Matchmaking parameters: how far apart two Elo ratings may be to pair, and
/// how that tolerance grows while a player waits. Windows are mutual — a pair
/// forms only when each player's window covers the gap — so nobody is handed
/// an opponent they wouldn't accept themselves.
struct MatchmakingConfig: Sendable {
    /// Elo distance a fresh entrant accepts.
    var initialWindow: Double
    /// Window growth per second waited. Uncapped, so any two waiting players
    /// become compatible eventually — nobody starves.
    var widenPerSecond: Double
    /// How often pools are rescanned for pairs that widening enabled.
    var sweepInterval: Duration

    static let standard = MatchmakingConfig(
        initialWindow: 100,
        widenPerSecond: 10,
        sweepInterval: .seconds(1)
    )
}

/// Owns all realtime state: the matchmaking queue and live games. The server
/// is authoritative — every move is validated with ChessKit before broadcast,
/// and clocks/timeouts are enforced here. All mutation happens on this actor;
/// sockets are only written to from here.
actor GameCoordinator {
    /// Default time a disconnected player has to return before forfeiting.
    static let defaultAbandonGracePeriod: Duration = .seconds(60)

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
        /// Per-color forfeit timers. Keyed by color so a reconnecting player
        /// cancels only their own pending forfeit — never their still-absent
        /// opponent's. (A single shared task let one player's return cancel the
        /// other's abandonment forfeit when both had dropped.)
        var abandonTasks: [PieceColor: Task<Void, Never>] = [:]

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

        /// Cancels and clears the pending abandonment forfeit for one color.
        func cancelAbandonTask(for color: PieceColor) {
            abandonTasks[color]?.cancel()
            abandonTasks[color] = nil
        }

        /// Cancels both colors' forfeit timers (game teardown).
        func cancelAllAbandonTasks() {
            for task in abandonTasks.values { task.cancel() }
            abandonTasks.removeAll()
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

        /// Remaining time for the side to move, net of the in-progress turn.
        /// A value <= 0 means the mover's flag has fallen. Read-only, so a
        /// late move can be rejected without mutating the clock — an illegal
        /// move then cannot farm the increment or reset the timer (#142).
        func moverRemaining() -> Double {
            let stored = game.sideToMove == .white ? whiteSeconds : blackSeconds
            return stored - secondsSinceTurnStart()
        }

        /// Commits a validated turn to `side`'s clock: charge the elapsed
        /// think time, add the increment, and start the opponent's turn.
        /// Called only after the move is known legal, so an illegal move never
        /// touches the clock. `side` is explicit because `game.sideToMove` has
        /// already flipped by the time this runs.
        func commitMove(by side: PieceColor, increment: Double) {
            let elapsed = secondsSinceTurnStart()
            if side == .white {
                whiteSeconds = max(0, whiteSeconds - elapsed) + increment
            } else {
                blackSeconds = max(0, blackSeconds - elapsed) + increment
            }
            turnStartedAt = .now
        }
    }

    /// A finished game's players, kept around so both can agree to a rematch.
    private struct RematchSlot {
        let whiteID: UUID
        let blackID: UUID
        /// A rematch is played at the same control as the finished game.
        let timeControl: TimeControl
        var requested: Set<UUID> = []
        /// Expires the slot when the rematch window closes unanswered;
        /// cancelled when the slot is dropped for any other reason.
        var expiryTask: Task<Void, Never>?

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
    /// A player waiting in a matchmaking pool.
    private struct QueueEntry {
        let seat: Seat
        let joinedAt: ContinuousClock.Instant

        /// The Elo distance this player accepts after waiting this long.
        func window(at now: ContinuousClock.Instant, config: MatchmakingConfig) -> Double {
            let waited = now - joinedAt
            let seconds = Double(waited.components.seconds)
                + Double(waited.components.attoseconds) / 1e18
            return config.initialWindow + config.widenPerSecond * seconds
        }
    }

    /// One matchmaking pool per time control; players are only paired within
    /// the pool they asked for.
    private var queues: [TimeControl: [QueueEntry]] = [:]
    /// Rescans pools while anyone is waiting; nil when all pools are empty.
    private var sweepTask: Task<Void, Never>?
    private var gamesByID: [UUID: LiveGame] = [:]
    private var gameIDByUser: [UUID: UUID] = [:]
    private var socketsByUser: [UUID: WebSocket] = [:]
    /// Keyed by finished game ID; also indexed per player for lookup.
    private var rematchSlots: [UUID: RematchSlot] = [:]
    private var rematchSlotByUser: [UUID: UUID] = [:]

    /// How long after a game ends a rematch can still be agreed; afterwards
    /// the slot expires and both players are told the offer is gone.
    private let rematchWindow: Duration
    /// Rating-window pairing rules; tests inject fast-widening variants.
    private let matchmaking: MatchmakingConfig
    /// Grace before a disconnected player forfeits; tests inject a short one.
    private let abandonGracePeriod: Duration

    init(
        app: Application,
        clock: ClockConfig? = nil,
        rematchWindow: Duration = .seconds(60),
        matchmaking: MatchmakingConfig = .standard,
        abandonGracePeriod: Duration = GameCoordinator.defaultAbandonGracePeriod
    ) {
        self.app = app
        self.clockOverride = clock
        self.rematchWindow = rematchWindow
        self.matchmaking = matchmaking
        self.abandonGracePeriod = abandonGracePeriod
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
        if let game = activeGame(for: userID), let color = game.color(of: userID) {
            game.setSocket(socket, for: userID)
            game.cancelAbandonTask(for: color)
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

        guard let game = activeGame(for: userID), let color = game.color(of: userID) else { return }
        game.setSocket(nil, for: userID)
        send(.opponentStatus(connected: false), to: game.opponentSeat(of: userID)?.socket)

        // Forfeit if the player doesn't come back in time. (The chess clock
        // keeps running regardless and may end the game sooner.) Keyed by
        // color so this timer is independent of the opponent's — if both drop
        // and one returns, the other's forfeit still stands.
        let gameID = game.id
        let grace = abandonGracePeriod
        game.cancelAbandonTask(for: color)
        game.abandonTasks[color] = Task { [weak self] in
            try? await Task.sleep(for: grace)
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
        slot.expiryTask?.cancel()
        rematchSlotByUser[slot.whiteID] = nil
        rematchSlotByUser[slot.blackID] = nil
    }

    /// The rematch window closed with nobody (or only one side) agreeing:
    /// both players hear the offer is gone, so a waiting requester stops
    /// waiting and an unanswered offer disappears from the opponent's sheet.
    private func expireRematchSlot(_ slotID: UUID) {
        guard let slot = rematchSlots[slotID] else { return }
        dropRematchSlot(slotID)
        send(.rematchUnavailable, to: socketsByUser[slot.whiteID])
        send(.rematchUnavailable, to: socketsByUser[slot.blackID])
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

        // Only pair players who asked for the same time control, and only
        // within rating windows: the closest-rated compatible opponent wins,
        // not the longest-waiting one.
        let entry = QueueEntry(seat: seat, joinedAt: .now)
        var pool = queues[timeControl, default: []]
        if let index = closestCompatibleIndex(to: entry, in: pool, at: .now) {
            let opponent = pool.remove(at: index)
            queues[timeControl] = pool
            startGameRandomColors(entry.seat, opponent.seat, timeControl: timeControl)
        } else {
            pool.append(entry)
            queues[timeControl] = pool
            send(.queued, to: socket)
            ensureSweeping()
        }
    }

    private func removeFromAllQueues(userID: UUID) {
        for control in queues.keys {
            queues[control]?.removeAll { $0.seat.userID == userID }
        }
    }

    // MARK: - Rating-window matchmaking

    /// Index of the compatible opponent with the smallest rating gap, if any.
    private func closestCompatibleIndex(
        to entry: QueueEntry,
        in pool: [QueueEntry],
        at now: ContinuousClock.Instant
    ) -> Int? {
        var best: (index: Int, gap: Int)?
        for (index, candidate) in pool.enumerated() {
            let gap = abs(candidate.seat.rating - entry.seat.rating)
            guard Double(gap) <= min(candidate.window(at: now, config: matchmaking),
                                     entry.window(at: now, config: matchmaking)),
                gap < (best?.gap ?? .max)
            else { continue }
            best = (index, gap)
        }
        return best?.index
    }

    /// Random colors: fair over time and resistant to queue sniping.
    private func startGameRandomColors(_ a: Seat, _ b: Seat, timeControl: TimeControl) {
        if Bool.random() {
            startGame(white: a, black: b, timeControl: timeControl)
        } else {
            startGame(white: b, black: a, timeControl: timeControl)
        }
    }

    /// Keeps a sweep loop alive while anyone is queued, pairing players whose
    /// windows widen into compatibility. The next join restarts it after all
    /// pools empty out.
    private func ensureSweeping() {
        guard sweepTask == nil else { return }
        let interval = matchmaking.sweepInterval
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, await self.sweepAndContinue() else { return }
            }
        }
    }

    /// One sweep tick; false ends the loop once every pool is empty.
    private func sweepAndContinue() -> Bool {
        sweepPools()
        if queues.values.allSatisfy(\.isEmpty) {
            sweepTask = nil
            return false
        }
        return true
    }

    /// Pairs everyone whose windows have widened into compatibility, closest
    /// gaps first. Pools are small, so the quadratic scan is fine.
    private func sweepPools() {
        let now = ContinuousClock.now
        for control in queues.keys {
            var pool = queues[control] ?? []
            var paired: [(Seat, Seat)] = []
            while pool.count >= 2 {
                var best: (i: Int, j: Int, gap: Int)?
                for i in pool.indices {
                    for j in pool.indices where j > i {
                        let gap = abs(pool[i].seat.rating - pool[j].seat.rating)
                        guard Double(gap) <= min(pool[i].window(at: now, config: matchmaking),
                                                 pool[j].window(at: now, config: matchmaking)),
                            gap < (best?.gap ?? .max)
                        else { continue }
                        best = (i, j, gap)
                    }
                }
                guard let match = best else { break }
                let second = pool.remove(at: match.j)
                let first = pool.remove(at: match.i)
                paired.append((first.seat, second.seat))
            }
            queues[control] = pool
            for (a, b) in paired {
                startGameRandomColors(a, b, timeControl: control)
            }
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

        // Flag check first, read-only: a move that arrives after the mover's
        // flag fell still loses on time even if the timeout task hasn't fired.
        // Doing this without mutating the clock means a move that turns out
        // illegal cannot farm the increment or reset the think-timer (#142) —
        // only the validated move below commits the clock.
        guard game.moverRemaining() > 0 else {
            if color == .white { game.whiteSeconds = 0 } else { game.blackSeconds = 0 }
            await flagFell(game)
            return
        }

        do {
            try game.game.play(uci: uci)
        } catch {
            send(.errorMessage("illegal move"), to: socket)
            return
        }

        // Legal move committed (sideToMove has flipped): charge the mover's
        // think time, add the increment, and pass the turn.
        game.commitMove(by: color, increment: game.clock.incrementSeconds)

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
        game.cancelAllAbandonTasks()
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

        let slotID = game.id
        rematchSlots[game.id]?.expiryTask = Task { [weak self, rematchWindow] in
            try? await Task.sleep(for: rematchWindow)
            guard !Task.isCancelled else { return }
            await self?.expireRematchSlot(slotID)
        }

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
            uciMoves: game.game.uciMoves.joined(separator: " "),
            timeControl: game.timeControl.rawValue
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
