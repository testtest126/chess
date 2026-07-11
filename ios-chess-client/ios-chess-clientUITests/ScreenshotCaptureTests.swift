import XCTest

/// On-demand README/marketing screenshot capture (issue #118 — not a CI
/// gate): walks the app to its photogenic screens and keeps device-framed
/// PNGs as attachments for `xcrun xcresulttool export attachments`. The
/// screenshots workflow (.github/workflows/screenshots.yml) normalizes the
/// simulator status bar to 9:41 before running this, then exports and
/// commits the results.
///
/// Run it explicitly:
///   TEST_RUNNER_CAPTURE_SCREENSHOTS=1 xcodebuild test … \
///     -only-testing:ios-chess-clientUITests/ScreenshotCaptureTests
///
/// Skips itself otherwise, and CI's -only-testing selection never includes
/// it. Capture is best-effort by design: a move that can't be staged is
/// skipped rather than failing the run — a slightly different position is
/// still a usable screenshot, whereas a red run produces nothing.
final class ScreenshotCaptureTests: XCTestCase {
    /// Existence/hittability budget scaled for cold CI simulators, matching
    /// GameFlowUITests.
    private static let ciTimeout: TimeInterval = 30

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCaptureHomeGameAndReview() throws {
        guard ProcessInfo.processInfo.environment["CAPTURE_SCREENSHOTS"] == "1" else {
            throw XCTSkip("on-demand capture: set TEST_RUNNER_CAPTURE_SCREENSHOTS=1 to run")
        }
        let app = XCUIApplication()
        app.launch()

        // Home, once it has settled.
        XCTAssertTrue(app.buttons["Start Game"].waitForExistence(timeout: Self.ciTimeout),
                      "home screen should appear")
        attachScreenshot(app, name: "readme-home")

        tapStartGame(in: app)
        guard app.descendants(matching: .any)["square_e2"].waitForExistence(timeout: Self.ciTimeout) else {
            return XCTFail("board did not appear")
        }

        // Stage a few opening moves so the board reads as a real game. Each
        // white move here is legal against any engine reply (1. e4, 2. Nf3,
        // 3. Bc4 — no reply can occupy or block their paths that early), but
        // every step stays best-effort anyway.
        stageMove(in: app, from: "e2", to: "e4", san: "e4")
        stageMove(in: app, from: "g1", to: "f3", san: "Nf3")
        stageMove(in: app, from: "f1", to: "c4", san: "Bc4")

        waitForEngineIdle(in: app)
        attachScreenshot(app, name: "readme-game")

        // Resign to reach the review flow (mirrors GameFlowUITests.endGame).
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

    /// Plays a move by tapping its squares once the engine is idle. Missing
    /// confirmation is logged, not fatal — see the type comment.
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

    /// Waits out the engine's thinking indicator so taps land on our turn
    /// and captures don't show a spinner.
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

    /// Same below-the-fold defense as GameFlowUITests: XCUITest doesn't
    /// auto-scroll, and "Start Game" can sit under the fold.
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
