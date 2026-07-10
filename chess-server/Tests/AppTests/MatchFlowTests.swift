@testable import App
import XCTVapor
import WebSocketKit
import NIOCore
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

    /// Registers two players, queues both, and sorts out who got which color
    /// (assignment is random).
    func startMatch() async throws -> Match {
        let a = try await register()
        let b = try await register()

        let socketA = try await TestSocket.connect(port: port, token: a.accessToken, on: app.eventLoopGroup)
        try await socketA.send(.joinQueue)
        guard case .queued = try await socketA.next() else {
            throw TestSocketError.unexpectedMessage
        }

        let socketB = try await TestSocket.connect(port: port, token: b.accessToken, on: app.eventLoopGroup)
        try await socketB.send(.joinQueue)

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

        // Fresh game ships full clocks and the opponent's rating.
        let clock = try XCTUnwrap(match.whiteStart.clock)
        XCTAssertEqual(clock.whiteSeconds, ClockConfig.standard.initialSeconds, accuracy: 1)
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

    func testUnauthenticatedSocketIsClosed() async throws {
        do {
            let socket = try await TestSocket.connect(port: port, token: "garbage", on: app.eventLoopGroup)
            // Server may accept the upgrade then close immediately; sending
            // should fail or the connection should already be closed.
            try await socket.send(.joinQueue)
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
