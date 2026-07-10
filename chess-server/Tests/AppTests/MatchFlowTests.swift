@testable import App
import XCTVapor
import WebSocketKit
import NIOCore
import Fluent
import ChessOnline

/// Full-stack integration tests: boots the server on an ephemeral port and
/// plays real matches between two WebSocket clients.
final class MatchFlowTests: XCTestCase {
    var app: Application!
    var port: Int!

    override func setUp() async throws {
        app = try await Application.make(.testing)
        try await configure(app)
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0
        app.environment.arguments = ["serve"]
        try await app.startup()
        port = try XCTUnwrap(app.http.server.shared.localAddress?.port)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        app = nil
    }

    // MARK: - HTTP helpers

    func register() async throws -> AuthResponse {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port!)/auth/register")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RegisterRequest())
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try JSONDecoder().decode(AuthResponse.self, from: data)
    }

    func me(token: String) async throws -> UserDTO {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port!)/me")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try JSONDecoder().decode(UserDTO.self, from: data)
    }

    func myGames(token: String) async throws -> [GameRecordDTO] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port!)/games")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([GameRecordDTO].self, from: data)
    }

    // MARK: - Match setup

    struct Match {
        let white: TestSocket
        let black: TestSocket
        let whiteAuth: AuthResponse
        let blackAuth: AuthResponse
        let whiteStart: ServerMessage.GameStart
    }

    /// Registers two players, queues both for the same control, and sorts out
    /// who got which color (assignment is random).
    func startMatch(timeControl: TimeControl = .default) async throws -> Match {
        let a = try await register()
        let b = try await register()

        let socketA = try await TestSocket.connect(port: port, token: a.accessToken, on: app.eventLoopGroup)
        try await socketA.send(.joinQueue(timeControl: timeControl))
        guard case .queued = try await socketA.next() else {
            throw TestSocketError.unexpectedMessage
        }

        let socketB = try await TestSocket.connect(port: port, token: b.accessToken, on: app.eventLoopGroup)
        try await socketB.send(.joinQueue(timeControl: timeControl))

        guard case .gameStart(let startA) = try await socketA.next(),
              case .gameStart(let startB) = try await socketB.next()
        else {
            throw TestSocketError.unexpectedMessage
        }
        XCTAssertEqual(startA.gameID, startB.gameID)
        XCTAssertNotEqual(startA.yourColor, startB.yourColor)

        if startA.yourColor == "white" {
            return Match(white: socketA, black: socketB, whiteAuth: a, blackAuth: b, whiteStart: startA)
        } else {
            return Match(white: socketB, black: socketA, whiteAuth: b, blackAuth: a, whiteStart: startB)
        }
    }

    // MARK: - Tests

    func testFullMatchOverWebSockets() async throws {
        let match = try await startMatch()

        // Fresh game ships full clocks, the control, and the opponent's rating.
        let clock = try XCTUnwrap(match.whiteStart.clock)
        XCTAssertEqual(clock.whiteSeconds, ClockConfig.standard.initialSeconds, accuracy: 1)
        XCTAssertEqual(match.whiteStart.timeControl, .default)
        XCTAssertEqual(match.whiteStart.opponentRating, User.initialRating)

        // Moving out of turn is rejected.
        try await match.black.send(.move(uci: "e7e5"))
        guard case .errorMessage = try await match.black.next() else {
            return XCTFail("expected out-of-turn rejection")
        }

        // An illegal move is rejected.
        try await match.white.send(.move(uci: "e2e5"))
        guard case .errorMessage = try await match.white.next() else {
            return XCTFail("expected illegal move rejection")
        }

        // Fool's mate: 1. f3 e5 2. g4 Qh4#
        for (socket, uci) in [(match.white, "f2f3"), (match.black, "e7e5"),
                              (match.white, "g2g4"), (match.black, "d8h4")] {
            try await socket.send(.move(uci: uci))
            guard case .movePlayed(let echoedW, let clockW) = try await match.white.next(),
                  case .movePlayed(let echoedB, _) = try await match.black.next()
            else {
                return XCTFail("expected move broadcast for \(uci)")
            }
            XCTAssertEqual(echoedW, uci)
            XCTAssertEqual(echoedB, uci)
            XCTAssertNotNil(clockW, "moves should carry clock state")
        }

        guard case .gameOver(let overW) = try await match.white.next(),
              case .gameOver = try await match.black.next()
        else {
            return XCTFail("expected game over")
        }
        XCTAssertEqual(overW.result, "0-1")
        XCTAssertEqual(overW.reason, "checkmate")
        // Equal 1200s, K=32: winner +16, loser -16.
        XCTAssertEqual(overW.ratingDeltaWhite, -16)
        XCTAssertEqual(overW.ratingDeltaBlack, 16)

        let whiteUser = try await me(token: match.whiteAuth.accessToken)
        let blackUser = try await me(token: match.blackAuth.accessToken)
        XCTAssertEqual(whiteUser.rating, 1184)
        XCTAssertEqual(blackUser.rating, 1216)

        // The finished game was persisted for both players.
        let whiteGames = try await myGames(token: match.whiteAuth.accessToken)
        XCTAssertEqual(whiteGames.count, 1)
        XCTAssertEqual(whiteGames[0].result, "0-1")
        XCTAssertEqual(whiteGames[0].uciMoves, "f2f3 e7e5 g2g4 d8h4")
        let blackGames = try await myGames(token: match.blackAuth.accessToken)
        XCTAssertEqual(blackGames.count, 1)

        try await match.white.close()
        try await match.black.close()
    }

    func testResignEndsGame() async throws {
        let match = try await startMatch()

        try await match.white.send(.resign)
        guard case .gameOver(let over) = try await match.black.next() else {
            return XCTFail("expected game over after resignation")
        }
        XCTAssertEqual(over.result, "0-1")
        XCTAssertEqual(over.reason, "resignation")

        try await match.white.close()
        try await match.black.close()
    }

    func testDrawOfferAcceptFlow() async throws {
        let match = try await startMatch()

        // Declining leaves the game running.
        try await match.white.send(.offerDraw)
        guard case .drawOffered = try await match.black.next() else {
            return XCTFail("expected draw offer relay")
        }
        try await match.black.send(.declineDraw)
        guard case .drawDeclined = try await match.white.next() else {
            return XCTFail("expected decline relay")
        }

        // A fresh offer accepted ends the game as agreed draw, rated 0/0.
        try await match.white.send(.offerDraw)
        guard case .drawOffered = try await match.black.next() else {
            return XCTFail("expected second draw offer relay")
        }
        try await match.black.send(.acceptDraw)
        guard case .gameOver(let over) = try await match.white.next() else {
            return XCTFail("expected game over after acceptance")
        }
        XCTAssertEqual(over.result, "1/2-1/2")
        XCTAssertEqual(over.reason, "drawAgreement")
        XCTAssertEqual(over.ratingDeltaWhite, 0)
        XCTAssertEqual(over.ratingDeltaBlack, 0)

        try await match.white.close()
        try await match.black.close()
    }

    func testTimeoutForfeitsGame() async throws {
        // Replace the coordinator with a sub-second clock for this test.
        app.gameCoordinator = GameCoordinator(
            app: app,
            clock: ClockConfig(initialSeconds: 0.6, incrementSeconds: 0)
        )

        let match = try await startMatch()

        // White never moves; the flag falls and Black wins on time.
        guard case .gameOver(let over) = try await match.black.next(timeoutSeconds: 5) else {
            return XCTFail("expected timeout game over")
        }
        XCTAssertEqual(over.result, "0-1")
        XCTAssertEqual(over.reason, "timeout")

        try await match.white.close()
        try await match.black.close()
    }

    func testMatchmakingIsolatesTimeControls() async throws {
        // Four players, two controls, interleaved joins: bullet players pair
        // only with each other, rapid players only with each other, and each
        // game starts with its own control's clock.
        let a = try await register()
        let b = try await register()
        let c = try await register()
        let d = try await register()

        let bulletA = try await TestSocket.connect(port: port, token: a.accessToken, on: app.eventLoopGroup)
        try await bulletA.send(.joinQueue(timeControl: .bullet))
        guard case .queued = try await bulletA.next() else {
            throw TestSocketError.unexpectedMessage
        }

        // A rapid player does NOT match the waiting bullet player.
        let rapidB = try await TestSocket.connect(port: port, token: b.accessToken, on: app.eventLoopGroup)
        try await rapidB.send(.joinQueue(timeControl: .rapid))
        guard case .queued = try await rapidB.next() else {
            return XCTFail("rapid player must not pair with the queued bullet player")
        }

        // A second bullet player pairs with the first, at bullet clocks...
        let bulletC = try await TestSocket.connect(port: port, token: c.accessToken, on: app.eventLoopGroup)
        try await bulletC.send(.joinQueue(timeControl: .bullet))
        guard case .gameStart(let startA) = try await bulletA.next(),
              case .gameStart(let startC) = try await bulletC.next()
        else {
            return XCTFail("expected the two bullet players to be paired")
        }
        XCTAssertEqual(startA.gameID, startC.gameID)
        XCTAssertEqual(startA.timeControl, .bullet)
        XCTAssertEqual(startC.timeControl, .bullet)
        let bulletClock = try XCTUnwrap(startA.clock)
        XCTAssertEqual(bulletClock.whiteSeconds, TimeControl.bullet.initialSeconds, accuracy: 1)
        XCTAssertEqual(bulletClock.blackSeconds, TimeControl.bullet.initialSeconds, accuracy: 1)

        // ...and a second rapid player with the waiting rapid one.
        let rapidD = try await TestSocket.connect(port: port, token: d.accessToken, on: app.eventLoopGroup)
        try await rapidD.send(.joinQueue(timeControl: .rapid))
        guard case .gameStart(let startB) = try await rapidB.next(),
              case .gameStart(let startD) = try await rapidD.next()
        else {
            return XCTFail("expected the two rapid players to be paired")
        }
        XCTAssertEqual(startB.gameID, startD.gameID)
        XCTAssertNotEqual(startB.gameID, startA.gameID)
        XCTAssertEqual(startB.timeControl, .rapid)
        let rapidClock = try XCTUnwrap(startD.clock)
        XCTAssertEqual(rapidClock.whiteSeconds, TimeControl.rapid.initialSeconds, accuracy: 1)
        XCTAssertEqual(rapidClock.blackSeconds, TimeControl.rapid.initialSeconds, accuracy: 1)

        for socket in [bulletA, rapidB, bulletC, rapidD] {
            try await socket.close()
        }
    }

    func testRematchKeepsTimeControl() async throws {
        let match = try await startMatch(timeControl: .bullet)
        XCTAssertEqual(match.whiteStart.timeControl, .bullet)

        try await match.white.send(.resign)
        _ = try await match.white.next() // game over
        _ = try await match.black.next() // game over

        try await match.white.send(.requestRematch)
        guard case .rematchOffered = try await match.black.next() else {
            return XCTFail("expected rematch offer relay")
        }
        try await match.black.send(.requestRematch)

        guard case .gameStart(let startA) = try await match.white.next(),
              case .gameStart(let startB) = try await match.black.next()
        else {
            return XCTFail("expected rematch game start")
        }
        // The rematch is played at the original control, with fresh clocks.
        XCTAssertEqual(startA.timeControl, .bullet)
        XCTAssertEqual(startB.timeControl, .bullet)
        let clock = try XCTUnwrap(startA.clock)
        XCTAssertEqual(clock.whiteSeconds, TimeControl.bullet.initialSeconds, accuracy: 1)
        XCTAssertEqual(clock.blackSeconds, TimeControl.bullet.initialSeconds, accuracy: 1)

        try await match.white.close()
        try await match.black.close()
    }

    func testLeaderboardRanksPlayersWithGames() async throws {
        let match = try await startMatch()

        // Before anyone finishes a game the leaderboard is empty.
        let before = try await leaderboard(token: match.whiteAuth.accessToken)
        XCTAssertTrue(before.isEmpty)

        try await match.white.send(.resign)
        _ = try await match.black.next() // game over

        let entries = try await leaderboard(token: match.whiteAuth.accessToken)
        XCTAssertEqual(entries.count, 2)
        // Black won: ranked first with the higher rating.
        XCTAssertEqual(entries[0].rating, 1216)
        XCTAssertEqual(entries[1].rating, 1184)
        XCTAssertEqual(entries[0].games, 1)
        XCTAssertTrue(entries[0].rating > entries[1].rating)

        try await match.white.close()
        try await match.black.close()
    }

    func leaderboard(token: String) async throws -> [LeaderboardEntry] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port!)/leaderboard")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try JSONDecoder().decode([LeaderboardEntry].self, from: data)
    }

    func profile(of playerID: UUID, token: String) async throws -> (HTTPStatus, PlayerProfileDTO?) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port!)/players/\(playerID.uuidString)")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = HTTPStatus(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (status, try? decoder.decode(PlayerProfileDTO.self, from: data))
    }

    func testPlayerProfileAggregatesRecordAcrossColors() async throws {
        // Game 1: white resigns → black wins.
        let match = try await startMatch()
        try await match.white.send(.resign)
        _ = try await match.white.next() // game over
        _ = try await match.black.next() // game over

        // Game 2 (rematch, colors swapped): agreed draw.
        try await match.white.send(.requestRematch)
        _ = try await match.black.next() // rematch offered
        try await match.black.send(.requestRematch)
        _ = try await match.white.next() // game start
        _ = try await match.black.next() // game start
        try await match.white.send(.offerDraw)
        _ = try await match.black.next() // draw offered
        try await match.black.send(.acceptDraw)
        _ = try await match.white.next() // game over
        _ = try await match.black.next() // game over

        // The original White has: 1 loss (as white) + 1 draw (as black, after
        // the color swap). Any signed-in player can view the profile.
        let (status, dto) = try await profile(of: match.whiteAuth.userID, token: match.blackAuth.accessToken)
        XCTAssertEqual(status, .ok)
        let p = try XCTUnwrap(dto)
        XCTAssertEqual(p.displayName, match.whiteAuth.displayName)
        XCTAssertEqual(p.wins, 0)
        XCTAssertEqual(p.draws, 1)
        XCTAssertEqual(p.losses, 1)
        XCTAssertEqual(p.games, 2)
        // -16 for the loss; then +1 for drawing as the lower-rated side
        // (1184 vs 1216: expected ≈ 0.454, so a draw gains a point).
        XCTAssertEqual(p.rating, 1185)

        // The winner's mirror image.
        let (_, winner) = try await profile(of: match.blackAuth.userID, token: match.blackAuth.accessToken)
        XCTAssertEqual(try XCTUnwrap(winner).wins, 1)
        XCTAssertEqual(try XCTUnwrap(winner).draws, 1)
        XCTAssertEqual(try XCTUnwrap(winner).losses, 0)

        // Unknown player → 404; no auth → 401.
        let (missing, _) = try await profile(of: UUID(), token: match.blackAuth.accessToken)
        XCTAssertEqual(missing, .notFound)
        var anon = URLRequest(url: URL(string: "http://127.0.0.1:\(port!)/players/\(match.whiteAuth.userID.uuidString)")!)
        anon.httpMethod = "GET"
        let (_, anonResponse) = try await URLSession.shared.data(for: anon)
        XCTAssertEqual((anonResponse as? HTTPURLResponse)?.statusCode, 401)

        try await match.white.close()
        try await match.black.close()
    }

    func testRematchSwapsColorsAndUsesUpdatedRatings() async throws {
        let match = try await startMatch()

        try await match.white.send(.resign)
        _ = try await match.white.next() // game over
        _ = try await match.black.next() // game over

        // One side asks; the other is notified, then agrees.
        try await match.white.send(.requestRematch)
        guard case .rematchOffered = try await match.black.next() else {
            return XCTFail("expected rematch offer relay")
        }
        try await match.black.send(.requestRematch)

        guard case .gameStart(let startA) = try await match.white.next(),
              case .gameStart(let startB) = try await match.black.next()
        else {
            return XCTFail("expected rematch game start")
        }
        // Colors swap: the previous White now plays Black.
        XCTAssertEqual(startA.yourColor, "black")
        XCTAssertEqual(startB.yourColor, "white")
        XCTAssertTrue(startA.moves.isEmpty)
        // Ratings reflect the finished game (previous White resigned: 1184).
        XCTAssertEqual(startB.opponentRating, 1184)
        XCTAssertEqual(startA.opponentRating, 1216)

        // The new game is live: previous Black (now White) moves first.
        try await match.black.send(.move(uci: "e2e4"))
        guard case .movePlayed(let uci, _) = try await match.white.next() else {
            return XCTFail("expected move in rematch game")
        }
        XCTAssertEqual(uci, "e2e4")

        try await match.white.close()
        try await match.black.close()
    }

    func testDeclineRematchNotifiesRequester() async throws {
        let match = try await startMatch()

        try await match.white.send(.resign)
        _ = try await match.white.next() // game over
        _ = try await match.black.next() // game over

        try await match.white.send(.requestRematch)
        guard case .rematchOffered = try await match.black.next() else {
            return XCTFail("expected rematch offer relay")
        }

        // Explicit decline (the client's decline button): the requester gets
        // rematch_declined, distinct from the opponent-left withdrawal.
        try await match.black.send(.declineRematch)
        guard case .rematchDeclined = try await match.white.next() else {
            return XCTFail("expected explicit decline notice")
        }

        try await match.white.close()
        try await match.black.close()
    }

    func testRematchOfferExpires() async throws {
        // Replace the coordinator with a sub-second rematch window.
        app.gameCoordinator = GameCoordinator(app: app, rematchWindow: .milliseconds(800))

        let match = try await startMatch()

        try await match.white.send(.resign)
        _ = try await match.white.next() // game over
        _ = try await match.black.next() // game over

        // White asks; Black lets the offer sit until the window closes.
        try await match.white.send(.requestRematch)
        guard case .rematchOffered = try await match.black.next() else {
            return XCTFail("expected rematch offer relay")
        }

        // Both sides learn the window closed: the requester stops waiting
        // and the unanswered offer leaves the opponent's sheet.
        guard case .rematchUnavailable = try await match.white.next(timeoutSeconds: 5) else {
            return XCTFail("requester should be told the offer expired")
        }
        guard case .rematchUnavailable = try await match.black.next(timeoutSeconds: 5) else {
            return XCTFail("offeree should be told the offer expired")
        }

        // The slot is gone: a late request is rejected, but queueing for a
        // new opponent still works for both players.
        try await match.white.send(.requestRematch)
        guard case .errorMessage = try await match.white.next() else {
            return XCTFail("expired slot should reject rematch requests")
        }
        try await match.white.send(.joinQueue(timeControl: .default))
        guard case .queued = try await match.white.next() else {
            return XCTFail("expired slot must not block re-queueing")
        }
        try await match.black.send(.joinQueue(timeControl: .default))
        guard case .gameStart = try await match.black.next() else {
            return XCTFail("both players should be pairable after expiry")
        }

        try await match.white.close()
        try await match.black.close()
    }

    func testRematchUnavailableWhenOpponentQueuesElsewhere() async throws {
        let match = try await startMatch()

        try await match.white.send(.resign)
        _ = try await match.white.next() // game over
        _ = try await match.black.next() // game over

        try await match.white.send(.requestRematch)
        guard case .rematchOffered = try await match.black.next() else {
            return XCTFail("expected rematch offer relay")
        }

        // The opponent moves on to a new opponent instead.
        try await match.black.send(.joinQueue(timeControl: .default))
        guard case .rematchUnavailable = try await match.white.next() else {
            return XCTFail("expected rematch withdrawal notice")
        }

        try await match.white.close()
        try await match.black.close()
    }

    // MARK: - Rating-window matchmaking (#43)

    private func setRating(_ rating: Int, for auth: AuthResponse) async throws {
        let found = try await User.find(auth.userID, on: app.db)
        let user = try XCTUnwrap(found)
        user.rating = rating
        try await user.save(on: app.db)
    }

    private func queuedPlayer(rating: Int) async throws -> TestSocket {
        let auth = try await register()
        try await setRating(rating, for: auth)
        let socket = try await TestSocket.connect(port: port, token: auth.accessToken, on: app.eventLoopGroup)
        try await socket.send(.joinQueue(timeControl: .default))
        return socket
    }

    func testPairsByRatingNotArrivalOrder() async throws {
        // Windows never widen here: ±100 Elo, forever.
        app.gameCoordinator = GameCoordinator(
            app: app,
            matchmaking: MatchmakingConfig(
                initialWindow: 100, widenPerSecond: 0, sweepInterval: .milliseconds(50))
        )

        let low = try await queuedPlayer(rating: 900)
        guard case .queued = try await low.next() else { return XCTFail("expected queued") }
        // The FIFO head is 1000 Elo away and must NOT be paired…
        let far = try await queuedPlayer(rating: 1900)
        guard case .queued = try await far.next() else { return XCTFail("expected queued") }
        // …while the late arrival 50 away pairs immediately.
        let close = try await queuedPlayer(rating: 950)

        guard case .gameStart(let start) = try await close.next() else {
            return XCTFail("expected immediate close-rated pairing")
        }
        XCTAssertEqual(start.opponentRating, 900)
        guard case .gameStart = try await low.next() else {
            return XCTFail("expected the close-rated pair to start")
        }

        // The distant player keeps waiting under a non-widening window.
        do {
            let unexpected = try await far.next(timeoutSeconds: 0.5)
            XCTFail("distant player should still be queued, got \(unexpected)")
        } catch TestSocketError.timeout {}

        try await low.close()
        try await close.close()
        try await far.close()
    }

    func testWindowWidensUntilLonePairMatches() async throws {
        // ±100 at entry, widening fast: a 1000-Elo gap becomes compatible
        // after ~0.45s and the sweep pairs the two lone players — the
        // starvation-free guarantee.
        app.gameCoordinator = GameCoordinator(
            app: app,
            matchmaking: MatchmakingConfig(
                initialWindow: 100, widenPerSecond: 2000, sweepInterval: .milliseconds(50))
        )

        let a = try await queuedPlayer(rating: 900)
        guard case .queued = try await a.next() else { return XCTFail("expected queued") }
        let b = try await queuedPlayer(rating: 1900)
        guard case .queued = try await b.next() else { return XCTFail("expected queued") }

        guard case .gameStart(let startA) = try await a.next(timeoutSeconds: 5),
              case .gameStart(let startB) = try await b.next(timeoutSeconds: 5)
        else {
            return XCTFail("expected widening windows to pair the lone players")
        }
        XCTAssertEqual(startA.gameID, startB.gameID)
        // Color assignment stays random-and-complementary.
        XCTAssertNotEqual(startA.yourColor, startB.yourColor)
        XCTAssertEqual(startA.opponentRating, 1900)

        try await a.close()
        try await b.close()
    }

    func testUnauthenticatedSocketIsClosed() async throws {
        do {
            let socket = try await TestSocket.connect(port: port, token: "garbage", on: app.eventLoopGroup)
            // Server may accept the upgrade then close immediately; sending
            // should fail or the connection should already be closed.
            try await socket.send(.joinQueue(timeControl: .default))
            let closed = try await socket.waitForClose(timeoutSeconds: 5)
            XCTAssertTrue(closed, "socket with bad token should be closed")
        } catch {
            // Upgrade rejection is also acceptable.
        }
    }
}

// MARK: - WebSocket test harness

enum TestSocketError: Error {
    case timeout
    case unexpectedMessage
}

/// Minimal async wrapper around a WebSocketKit client connection.
actor TestSocket {
    private let ws: WebSocket
    private var iterator: AsyncStream<ServerMessage>.Iterator

    private init(ws: WebSocket, stream: AsyncStream<ServerMessage>) {
        self.ws = ws
        self.iterator = stream.makeAsyncIterator()
    }

    static func connect(port: Int, token: String, on group: any EventLoopGroup) async throws -> TestSocket {
        let (stream, continuation) = AsyncStream.makeStream(of: ServerMessage.self)
        let promise = group.next().makePromise(of: WebSocket.self)

        WebSocket.connect(
            to: "ws://127.0.0.1:\(port)/play",
            headers: ["Authorization": "Bearer \(token)"],
            on: group
        ) { ws in
            ws.onText { _, text in
                if let message = try? ServerMessage(jsonString: text) {
                    continuation.yield(message)
                }
            }
            ws.onClose.whenComplete { _ in continuation.finish() }
            promise.succeed(ws)
        }.cascadeFailure(to: promise)

        let ws = try await promise.futureResult.get()
        return TestSocket(ws: ws, stream: stream)
    }

    func send(_ message: ClientMessage) async throws {
        try await ws.send(message.jsonString())
    }

    func next(timeoutSeconds: Double = 10) async throws -> ServerMessage {
        let result = try await withThrowingTaskGroup(of: ServerMessage?.self) { group in
            group.addTask { await self.nextMessage() }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let result else { throw TestSocketError.timeout }
        return result
    }

    func waitForClose(timeoutSeconds: Double) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeoutSeconds)
        while ContinuousClock.now < deadline {
            if ws.isClosed { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return ws.isClosed
    }

    private func nextMessage() async -> ServerMessage? {
        // AsyncStream iterators box shared storage, so consuming through a
        // local copy (to satisfy actor isolation) still advances the stream.
        var localIterator = iterator
        let value = await localIterator.next()
        iterator = localIterator
        return value
    }

    func close() async throws {
        try await ws.close()
    }
}
