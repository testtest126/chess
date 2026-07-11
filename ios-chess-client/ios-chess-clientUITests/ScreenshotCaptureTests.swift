import XCTest
import ChessKit
import ChessOnline

/// The server the showcase path talks to; same convention as
/// OnlineMatchUITests (TEST_RUNNER_CHESS_SERVER_URL via xcodebuild).
private let serverBase = URL(string:
    ProcessInfo.processInfo.environment["CHESS_SERVER_URL"] ?? "http://127.0.0.1:8080")!

/// On-demand README/marketing screenshot capture (issue #118 — not a CI
/// gate): produces device-framed PNGs as attachments for
/// `xcrun xcresulttool export attachments`. The screenshots workflow
/// (.github/workflows/screenshots.yml) normalizes the status bar, records a
/// demo video of the run, executes this in light and dark appearance, then
/// exports and commits the results.
///
/// Two capture paths:
/// - SHOWCASE (chess-server reachable): a scripted opponent joins real
///   matchmaking and both sides play the Møller Attack tableau — castled
///   king, d5 wedge, pieces in tension — with live Blitz clocks on screen.
///   The opponent resigns at the end of the line, so the review screen
///   shows a *won* theory game with believable accuracy, and the home
///   screen is captured last with a real Past Games row.
/// - FALLBACK (no server): the original engine-game flow, so the workflow
///   still produces captures when the server can't boot.
///
/// Run it explicitly:
///   TEST_RUNNER_CAPTURE_SCREENSHOTS=1 xcodebuild test … \
///     -only-testing:ios-chess-clientUITests/ScreenshotCaptureTests
///
/// Skips itself otherwise; CI's -only-testing selection never includes it.
/// Capture is best-effort by design where possible: a degraded position is
/// still a usable screenshot, whereas a red run produces nothing.
final class ScreenshotCaptureTests: XCTestCase {
    private static let ciTimeout: TimeInterval = 30

    /// Møller Attack (Giuoco Piano): 1.e4 e5 2.Nf3 Nc6 3.Bc4 Bc5 4.c3 Nf6
    /// 5.d4 exd4 6.cxd4 Bb4+ 7.Nc3 Nxe4 8.O-O Bxc3 9.d5 — photogenic at the
    /// final ply, and a real theory line so review accuracy reads sane.
    private static let scriptUCI = [
        "e2e4", "e7e5", "g1f3", "b8c6", "f1c4", "f8c5", "c2c3", "g8f6",
        "d2d4", "e5d4", "c3d4", "c5b4", "b1c3", "f6e4", "e1g1", "b4c3", "d4d5",
    ]
    /// The same line as the SAN the move list will echo, used to wait on
    /// each ply landing.
    private static let scriptSAN = [
        "e4", "e5", "Nf3", "Nc6", "Bc4", "Bc5", "c3", "Nf6",
        "d4", "exd4", "cxd4", "Bb4+", "Nc3", "Nxe4", "O-O", "Bxc3", "d5",
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCaptureHomeGameAndReview() async throws {
        guard ProcessInfo.processInfo.environment["CAPTURE_SCREENSHOTS"] == "1" else {
            throw XCTSkip("on-demand capture: set TEST_RUNNER_CAPTURE_SCREENSHOTS=1 to run")
        }
        if await ShowcaseOpponent.probeServer() == nil {
            try await captureShowcase()
        } else {
            captureEngineFallback()
        }
    }

    // MARK: - Showcase path (scripted online game)

    @MainActor
    private func captureShowcase() async throws {
        let bot = ShowcaseOpponent(script: Self.scriptUCI)
        try await bot.registerAndQueue(timeControl: .blitz)

        let app = XCUIApplication()
        app.launchArguments += ["-server_base_url", serverBase.absoluteString]
        app.launch()

        tapWhenReady(app.buttons["Blitz"], "blitz segment")
        tapWhenReady(app.buttons["Play Online"], "play online button")
        XCTAssertTrue(app.descendants(matching: .any)["square_e2"].waitForExistence(timeout: 20),
                      "board should appear once matched")

        // Colors are random: if the opponent holds White it has already
        // played 1. e4 — otherwise the first scripted ply is ours.
        let appIsWhite = !app.staticTexts[Self.scriptSAN[0]].waitForExistence(timeout: 6)
        let start = appIsWhite ? 0 : 1
        for i in start..<Self.scriptUCI.count {
            let whiteToMove = i.isMultiple(of: 2)
            if whiteToMove == appIsWhite {
                let uci = Self.scriptUCI[i]
                tapWhenReady(app.descendants(matching: .any)["square_\(uci.prefix(2))"], "from square of \(uci)")
                tapWhenReady(app.descendants(matching: .any)["square_\(uci.dropFirst(2).prefix(2))"], "to square of \(uci)")
            }
            XCTAssertTrue(app.staticTexts[Self.scriptSAN[i]].waitForExistence(timeout: 25),
                          "ply \(i + 1) (\(Self.scriptSAN[i])) should land")
        }

        // The tableau, with both clocks live.
        try? await Task.sleep(for: .seconds(1))
        attachScreenshot(app, name: "readme-game")

        // The opponent resigns a few seconds after the final ply.
        XCTAssertTrue(app.staticTexts["You Won"].waitForExistence(timeout: 30),
                      "opponent should resign after the scripted line")
        tapWhenReady(app.buttons["Review Game"], "review button")
        if app.staticTexts["White"].waitForExistence(timeout: 120) {
            try? await Task.sleep(for: .seconds(1))
            attachScreenshot(app, name: "readme-review")
            tapWhenReady(app.buttons["Done"].firstMatch, "review done button")
        }

        // Home last, so Past Games carries the real row (thumbnail + result).
        tapWhenReady(app.buttons["Close"].firstMatch, "game over close button")
        XCTAssertTrue(app.buttons["Start Game"].waitForExistence(timeout: Self.ciTimeout),
                      "home screen should return")
        try? await Task.sleep(for: .seconds(1))
        attachScreenshot(app, name: "readme-home")

        await bot.close()
        app.terminate()
    }

    // MARK: - Fallback path (engine game, no server needed)

    @MainActor
    private func captureEngineFallback() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.buttons["Start Game"].waitForExistence(timeout: Self.ciTimeout),
                      "home screen should appear")
        attachScreenshot(app, name: "readme-home")

        tapStartGame(in: app)
        guard app.descendants(matching: .any)["square_e2"].waitForExistence(timeout: Self.ciTimeout) else {
            return XCTFail("board did not appear")
        }

        // Each white move below is legal against any engine reply; every
        // step stays best-effort — a skipped move degrades the position,
        // not the run.
        stageMove(in: app, from: "e2", to: "e4", san: "e4")
        stageMove(in: app, from: "g1", to: "f3", san: "Nf3")
        stageMove(in: app, from: "f1", to: "c4", san: "Bc4")

        waitForEngineIdle(in: app)
        attachScreenshot(app, name: "readme-game")

        tapWhenReady(app.buttons["Resign"].firstMatch, "resign toolbar button")
        let resignButtons = app.buttons.matching(NSPredicate(format: "label == 'Resign'"))
        let dialogOpen = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count >= 2"), object: resignButtons
        )
        XCTAssertEqual(XCTWaiter().wait(for: [dialogOpen], timeout: Self.ciTimeout), .completed,
                       "resign confirmation dialog should appear")
        resignButtons.allElementsBoundByIndex.last?.tap()
        XCTAssertTrue(app.staticTexts["You Lost"].waitForExistence(timeout: Self.ciTimeout),
                      "game over sheet should appear")

        tapWhenReady(app.buttons["Review Game"], "review button")
        if app.staticTexts["White"].waitForExistence(timeout: 90) {
            attachScreenshot(app, name: "readme-review")
            tapWhenReady(app.buttons["Done"].firstMatch, "review done button")
        }
        app.terminate()
    }

    // MARK: - Helpers

    @MainActor
    private func stageMove(in app: XCUIApplication, from: String, to: String, san: String) {
        waitForEngineIdle(in: app)
        let fromSquare = app.descendants(matching: .any)["square_\(from)"]
        let toSquare = app.descendants(matching: .any)["square_\(to)"]
        guard fromSquare.exists, fromSquare.isHittable, toSquare.exists else {
            print("[screenshots] skipping \(san): squares not tappable")
            return
        }
        fromSquare.tap()
        toSquare.tap()
        if !app.staticTexts[san].waitForExistence(timeout: Self.ciTimeout) {
            print("[screenshots] move \(san) not confirmed; continuing")
        }
    }

    @MainActor
    private func waitForEngineIdle(in app: XCUIApplication) {
        let thinking = app.activityIndicators.firstMatch
        if thinking.exists {
            let gone = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: thinking
            )
            _ = XCTWaiter().wait(for: [gone], timeout: 60)
        }
    }

    @MainActor
    private func tapStartGame(in app: XCUIApplication) {
        let button = app.buttons["Start Game"]
        XCTAssertTrue(button.waitForExistence(timeout: Self.ciTimeout), "home screen should show Start Game")
        var swipes = 0
        while !button.isHittable && swipes < 5 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(button.isHittable, "Start Game should be reachable by scrolling")
        button.tap()
    }

    @MainActor
    private func tapWhenReady(
        _ element: XCUIElement, _ what: String,
        timeout: TimeInterval = ScreenshotCaptureTests.ciTimeout,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout),
                      "\(what) should exist", file: file, line: line)
        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"), object: element
        )
        XCTAssertTrue(XCTWaiter().wait(for: [hittable], timeout: timeout) == .completed,
                      "\(what) should be hittable", file: file, line: line)
        element.tap()
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// A scripted opponent speaking the real wire protocol — the same shape as
/// OnlineMatchUITests's OpponentBot, but it plays a fixed line instead of
/// engine moves and resigns once the line is exhausted (a few seconds after
/// the last ply, leaving the UI time to capture the tableau).
private final class ShowcaseOpponent: @unchecked Sendable {
    private static var base: URL { serverBase }

    private static var playSocketURL: URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/play"
        return components.url!
    }

    private let script: [String]
    private var socket: URLSessionWebSocketTask?
    private var game = Game()
    private var color: PieceColor = .white
    private var resignScheduled = false

    init(script: [String]) {
        self.script = script
    }

    /// Nil when the server answered /health — the showcase path can run.
    static func probeServer() async -> Error? {
        var request = URLRequest(url: base.appending(path: "health"))
        request.timeoutInterval = 5
        do {
            _ = try await URLSession.shared.data(for: request)
            return nil
        } catch {
            return error
        }
    }

    func registerAndQueue(timeControl: TimeControl) async throws {
        var request = URLRequest(url: Self.base.appending(path: "auth/register"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RegisterRequest())
        let (data, _) = try await URLSession.shared.data(for: request)
        let auth = try JSONDecoder().decode(AuthResponse.self, from: data)

        var wsRequest = URLRequest(url: Self.playSocketURL)
        wsRequest.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: wsRequest)
        self.socket = socket
        socket.resume()

        // Queue before the app joins, so matchmaking pairs us with it.
        try await send(.joinQueue(timeControl: timeControl))
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
                await playScriptedIfOurTurn()
            case .movePlayed(let uci, _):
                _ = try? game.play(uci: uci)
                await playScriptedIfOurTurn()
                await resignWhenLineEnds()
            case .gameOver:
                return
            default:
                break
            }
        }
    }

    private func playScriptedIfOurTurn() async {
        guard !game.isOver, game.sideToMove == color, game.moveCount < script.count else { return }
        let uci = script[game.moveCount]
        _ = try? game.play(uci: uci)
        try? await send(.move(uci: uci))
        await resignWhenLineEnds()
    }

    /// Once the scripted line is fully on the board, wait long enough for
    /// the UI to take its capture, then concede.
    private func resignWhenLineEnds() async {
        guard game.moveCount >= script.count, !resignScheduled else { return }
        resignScheduled = true
        try? await Task.sleep(for: .seconds(8))
        try? await send(.resign)
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
