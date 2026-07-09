@testable import App
import XCTVapor
import WebSocketKit
import NIOCore
import ChessOnline

/// Full-stack integration test: boots the server on an ephemeral port and
/// plays a real match between two WebSocket clients.
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

    func myGames(token: String) async throws -> [GameRecordDTO] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port!)/games")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([GameRecordDTO].self, from: data)
    }

    // MARK: - The match

    func testFullMatchOverWebSockets() async throws {
        let alice = try await register()
        let bob = try await register()

        let aliceSocket = try await TestSocket.connect(port: port, token: alice.accessToken, on: app.eventLoopGroup)
        try await aliceSocket.send(.joinQueue)
        guard case .queued = try await aliceSocket.next() else {
            return XCTFail("expected queued ack")
        }

        let bobSocket = try await TestSocket.connect(port: port, token: bob.accessToken, on: app.eventLoopGroup)
        try await bobSocket.send(.joinQueue)

        // First in queue plays White.
        guard case .gameStart(let aliceStart) = try await aliceSocket.next(),
              case .gameStart(let bobStart) = try await bobSocket.next()
        else {
            return XCTFail("expected game start for both players")
        }
        XCTAssertEqual(aliceStart.yourColor, "white")
        XCTAssertEqual(bobStart.yourColor, "black")
        XCTAssertEqual(aliceStart.gameID, bobStart.gameID)
        XCTAssertEqual(aliceStart.opponentName, bob.displayName)
        XCTAssertTrue(aliceStart.moves.isEmpty)

        // Moving out of turn is rejected.
        try await bobSocket.send(.move(uci: "e7e5"))
        guard case .errorMessage = try await bobSocket.next() else {
            return XCTFail("expected out-of-turn rejection")
        }

        // An illegal move is rejected.
        try await aliceSocket.send(.move(uci: "e2e5"))
        guard case .errorMessage = try await aliceSocket.next() else {
            return XCTFail("expected illegal move rejection")
        }

        // Fool's mate: 1. f3 e5 2. g4 Qh4#
        for (socket, uci) in [(aliceSocket, "f2f3"), (bobSocket, "e7e5"),
                              (aliceSocket, "g2g4"), (bobSocket, "d8h4")] {
            try await socket.send(.move(uci: uci))
            guard case .movePlayed(let echoedA) = try await aliceSocket.next(),
                  case .movePlayed(let echoedB) = try await bobSocket.next()
            else {
                return XCTFail("expected move broadcast for \(uci)")
            }
            XCTAssertEqual(echoedA, uci)
            XCTAssertEqual(echoedB, uci)
        }

        guard case .gameOver(let result, let reason) = try await aliceSocket.next(),
              case .gameOver = try await bobSocket.next()
        else {
            return XCTFail("expected game over")
        }
        XCTAssertEqual(result, "0-1")
        XCTAssertEqual(reason, "checkmate")

        // The finished game was persisted for both players.
        let aliceGames = try await myGames(token: alice.accessToken)
        XCTAssertEqual(aliceGames.count, 1)
        XCTAssertEqual(aliceGames[0].result, "0-1")
        XCTAssertEqual(aliceGames[0].uciMoves, "f2f3 e7e5 g2g4 d8h4")
        XCTAssertEqual(aliceGames[0].whiteName, alice.displayName)

        let bobGames = try await myGames(token: bob.displayName.isEmpty ? bob.accessToken : bob.accessToken)
        XCTAssertEqual(bobGames.count, 1)

        try await aliceSocket.close()
        try await bobSocket.close()
    }

    func testResignEndsGame() async throws {
        let alice = try await register()
        let bob = try await register()

        let aliceSocket = try await TestSocket.connect(port: port, token: alice.accessToken, on: app.eventLoopGroup)
        try await aliceSocket.send(.joinQueue)
        _ = try await aliceSocket.next() // queued

        let bobSocket = try await TestSocket.connect(port: port, token: bob.accessToken, on: app.eventLoopGroup)
        try await bobSocket.send(.joinQueue)
        _ = try await aliceSocket.next() // game start
        _ = try await bobSocket.next() // game start

        try await aliceSocket.send(.resign) // white resigns
        guard case .gameOver(let result, let reason) = try await bobSocket.next() else {
            return XCTFail("expected game over after resignation")
        }
        XCTAssertEqual(result, "0-1")
        XCTAssertEqual(reason, "resignation")

        try await aliceSocket.close()
        try await bobSocket.close()
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
