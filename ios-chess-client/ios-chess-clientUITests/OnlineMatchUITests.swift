import XCTest
import ChessKit
import ChessProtocol
import ChessOnline

/// End-to-end online play against a real server on 127.0.0.1:8080.
///
/// The test process doubles as the opponent: it registers its own guest
/// account, joins the matchmaking queue over a WebSocket, and answers with
/// engine moves — then the UI drives the app through matchmaking, a move,
/// resignation, and review. Skipped automatically when the server isn't up.
final class OnlineMatchUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testOnlineMatchAgainstBot() async throws {
        guard await OpponentBot.serverIsReachable() else {
            throw XCTSkip("chess-server not running on 127.0.0.1:8080")
        }

        // The opponent queues first, so it gets White and the app gets Black.
        let bot = OpponentBot()
        try await bot.registerAndQueue()

        let app = XCUIApplication()
        app.launch()
        app.buttons["Play Online"].tap()

        // Match forms as soon as the app joins the queue; the bot opens 1. e4.
        let openingMove = app.staticTexts["e4"]
        XCTAssertTrue(openingMove.waitForExistence(timeout: 15), "bot's opening move should appear")

        // Reply 1... e5 by tapping.
        app.descendants(matching: .any)["square_e7"].tap()
        app.descendants(matching: .any)["square_e5"].tap()
        XCTAssertTrue(app.staticTexts["e5"].waitForExistence(timeout: 10), "our reply should be accepted and echoed")

        // Resign and confirm.
        app.buttons["Resign"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "label == 'Resign'")).allElementsBoundByIndex.last?.tap()

        XCTAssertTrue(app.staticTexts["You Lost"].waitForExistence(timeout: 10), "game over sheet should appear")

        // Post-game review over the online game's moves.
        app.buttons["Review Game"].tap()
        XCTAssertTrue(app.staticTexts["White"].waitForExistence(timeout: 30), "review summary should appear")
        app.buttons["Done"].firstMatch.tap()

        // Back home, the finished game is in Past Games with the bot's name.
        app.buttons["Close"].firstMatch.tap()
        let row = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", bot.displayName)
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "saved online game should list the opponent")

        await bot.close()
    }
}

/// A scripted opponent speaking the real wire protocol.
final class OpponentBot: @unchecked Sendable {
    private static let base = URL(string: "http://127.0.0.1:8080")!

    private var socket: URLSessionWebSocketTask?
    private var game = Game()
    private var color: PieceColor = .white
    private let engine = NegamaxEngine()
    private(set) var displayName = ""

    static func serverIsReachable() async -> Bool {
        var request = URLRequest(url: base.appending(path: "health"))
        request.timeoutInterval = 2
        return (try? await URLSession.shared.data(for: request)) != nil
    }

    func registerAndQueue() async throws {
        var request = URLRequest(url: Self.base.appending(path: "auth/register"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RegisterRequest())
        let (data, _) = try await URLSession.shared.data(for: request)
        let auth = try JSONDecoder().decode(AuthResponse.self, from: data)
        displayName = auth.displayName

        var wsRequest = URLRequest(url: URL(string: "ws://127.0.0.1:8080/play")!)
        wsRequest.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: wsRequest)
        self.socket = socket
        socket.resume()

        try await send(.joinQueue)
        // Wait for the queue acknowledgment before letting the app join, so
        // the bot is first in line (and thus plays White).
        while true {
            if case .queued = try await receive() { break }
        }

        Task { [weak self] in
            await self?.runGameLoop()
        }
    }

    private func runGameLoop() async {
        while let message = try? await receive() {
            switch message {
            case .gameStart(let start):
                color = start.yourColor == "white" ? .white : .black
                game = (try? Game.from(uciMoves: start.moves)) ?? Game()
                await moveIfOurTurn(scripted: "e2e4")
            case .movePlayed(let uci):
                try? game.play(uci: uci)
                await moveIfOurTurn(scripted: nil)
            case .gameOver:
                return
            default:
                break
            }
        }
    }

    private func moveIfOurTurn(scripted: String?) async {
        guard !game.isOver, game.sideToMove == color else { return }
        let uci: String
        if let scripted, game.moveCount == 0 {
            uci = scripted
        } else {
            guard let move = engine.search(game.board, limit: SearchLimit(depth: 2)).bestMove else { return }
            uci = move.uci
        }
        try? game.play(uci: uci)
        try? await send(.move(uci: uci))
    }

    private func send(_ message: ClientMessage) async throws {
        try await socket?.send(.string(message.jsonString()))
    }

    private func receive() async throws -> ServerMessage {
        while true {
            guard let socket else { throw URLError(.cancelled) }
            let raw = try await socket.receive()
            guard case .string(let text) = raw else { continue }
            if let message = try? ServerMessage(jsonString: text) {
                return message
            }
        }
    }

    func close() async {
        socket?.cancel(with: .normalClosure, reason: nil)
    }
}
