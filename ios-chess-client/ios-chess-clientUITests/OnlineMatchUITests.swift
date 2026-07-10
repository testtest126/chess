import XCTest
import ChessKit
import ChessProtocol
import ChessOnline

/// The server the whole E2E talks to — the app under test, the bot, and the
/// health probe. Set the CHESS_SERVER_URL environment variable
/// (TEST_RUNNER_CHESS_SERVER_URL via xcodebuild) to point the suite at
/// another server, e.g. a spare port when 8080 is already in use.
private let serverBase = URL(string:
    ProcessInfo.processInfo.environment["CHESS_SERVER_URL"] ?? "http://127.0.0.1:8080"
)!

/// End-to-end online play against a real server, `serverBase`.
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

        // The opponent bot queues first; color assignment is random.
        let bot = OpponentBot()
        try await bot.registerAndQueue(timeControl: .bullet)

        let app = XCUIApplication()
        app.launchArguments += ["-server_base_url", serverBase.absoluteString]
        app.launch()

        // Choose bullet in the lobby picker: this covers the picker → session
        // → join_queue wiring, not just the protocol default.
        app.buttons["Bullet 1+0"].tap()
        app.buttons["Play Online"].tap()

        // Match forms as soon as the app joins the queue.
        let board = app.descendants(matching: .any)["square_e2"]
        XCTAssertTrue(board.waitForExistence(timeout: 15), "board should appear once matched")

        // Clocks are shown for both sides, and the game is really played at
        // the chosen control: bullet clocks start from 1:00, so anything at
        // or under a minute proves we didn't fall back to blitz's 5:00.
        XCTAssertTrue(app.staticTexts["clock_white"].waitForExistence(timeout: 5), "white clock should render")
        XCTAssertTrue(app.staticTexts["clock_black"].exists, "black clock should render")
        XCTAssertTrue(app.navigationBars["Bullet 1+0"].exists, "in-game title should name the chosen control")
        for clockID in ["clock_white", "clock_black"] {
            let label = app.staticTexts[clockID].label
            XCTAssertTrue(
                label == "1:00" || label.hasPrefix("0:"),
                "\(clockID) should start from bullet's 1:00, got \(label)"
            )
        }

        // If the bot got White it opens 1. e4 immediately; otherwise we're
        // White and open ourselves. Either way we make exactly one move.
        if app.staticTexts["e4"].waitForExistence(timeout: 8) {
            // We are Black: reply 1... e5.
            app.descendants(matching: .any)["square_e7"].tap()
            app.descendants(matching: .any)["square_e5"].tap()
            XCTAssertTrue(app.staticTexts["e5"].waitForExistence(timeout: 10), "our reply should be accepted and echoed")
        } else {
            // We are White: open 1. e4; the bot answers with an engine move.
            app.descendants(matching: .any)["square_e2"].tap()
            app.descendants(matching: .any)["square_e4"].tap()
            XCTAssertTrue(app.staticTexts["e4"].waitForExistence(timeout: 10), "our move should be accepted and echoed")
        }

        // Resign and confirm.
        app.buttons["Resign"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "label == 'Resign'")).allElementsBoundByIndex.last?.tap()

        XCTAssertTrue(app.staticTexts["You Lost"].waitForExistence(timeout: 10), "game over sheet should appear")

        // The bot asks for a rematch on game over; accept it. A fresh game
        // starts (colors swapped) and the sheet dismisses.
        let acceptRematch = app.buttons["Accept Rematch"]
        XCTAssertTrue(acceptRematch.waitForExistence(timeout: 10), "bot's rematch offer should arrive")
        acceptRematch.tap()
        XCTAssertTrue(
            waitUntilGone(app.staticTexts["You Lost"], timeout: 10),
            "rematch should start a fresh game and dismiss the sheet"
        )
        XCTAssertTrue(app.navigationBars["Bullet 1+0"].exists, "rematch should stay at the original control")

        // Play one move in the rematch, colors reversed from game one.
        if app.staticTexts["e4"].waitForExistence(timeout: 8) {
            app.descendants(matching: .any)["square_e7"].tap()
            app.descendants(matching: .any)["square_e5"].tap()
            XCTAssertTrue(app.staticTexts["e5"].waitForExistence(timeout: 10), "rematch reply should be echoed")
        } else {
            app.descendants(matching: .any)["square_e2"].tap()
            app.descendants(matching: .any)["square_e4"].tap()
            XCTAssertTrue(app.staticTexts["e4"].waitForExistence(timeout: 10), "rematch move should be echoed")
        }

        // Resign the rematch too, then review from the sheet.
        app.buttons["Resign"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "label == 'Resign'")).allElementsBoundByIndex.last?.tap()
        XCTAssertTrue(app.staticTexts["You Lost"].waitForExistence(timeout: 10), "second game over sheet should appear")

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

    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}

/// A scripted opponent speaking the real wire protocol.
final class OpponentBot: @unchecked Sendable {
    private static let base = serverBase

    /// The /play WebSocket endpoint, derived from `base` (http → ws).
    private static var playSocketURL: URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/play"
        return components.url!
    }

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

    func registerAndQueue(timeControl: TimeControl = .default) async throws {
        var request = URLRequest(url: Self.base.appending(path: "auth/register"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RegisterRequest())
        let (data, _) = try await URLSession.shared.data(for: request)
        let auth = try JSONDecoder().decode(AuthResponse.self, from: data)
        displayName = auth.displayName

        var wsRequest = URLRequest(url: Self.playSocketURL)
        wsRequest.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: wsRequest)
        self.socket = socket
        socket.resume()

        // Queue at the same control the UI test picks in the lobby, so
        // matchmaking pairs the bot with the app.
        try await send(.joinQueue(timeControl: timeControl))
        // Wait for the queue acknowledgment before letting the app join, so
        // the bot is already waiting when the app queues (colors are random).
        while true {
            if case .queued = try await receive() { break }
        }

        Task { [weak self] in
            await self?.runGameLoop()
        }
    }

    private func runGameLoop() async {
        var gamesFinished = 0
        while let message = try? await receive() {
            switch message {
            case .gameStart(let start):
                color = start.yourColor == "white" ? .white : .black
                game = (try? Game.from(uciMoves: start.moves)) ?? Game()
                await moveIfOurTurn(scripted: "e2e4")
            case .movePlayed(let uci, _):
                _ = try? game.play(uci: uci)
                await moveIfOurTurn(scripted: nil)
            case .gameOver:
                gamesFinished += 1
                // Offer one rematch after the first game; stop after the second.
                if gamesFinished == 1 {
                    try? await send(.requestRematch)
                } else {
                    return
                }
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
        _ = try? game.play(uci: uci)
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
