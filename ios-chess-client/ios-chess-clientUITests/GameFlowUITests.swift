import XCTest

/// End-to-end smoke test: start a game, make a move, get an engine reply,
/// resign, and open the game review.
///
/// Two layers of CI defense, from two investigations of the same red lane:
/// the causal fixes (scroll to "Start Game" below the fold; end the game so
/// a pondering engine can't block termination) and defense-in-depth against
/// slow runners — readiness-gated taps and generous timeouts. CI simulators
/// run an order of magnitude slower than dev machines (this suite has taken
/// 130+ seconds on cold runners); long waits cost nothing on fast machines
/// because every wait returns the moment its condition holds.
final class GameFlowUITests: XCTestCase {

    /// Existence/hittability budget scaled for cold CI simulators.
    private static let ciTimeout: TimeInterval = 30

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPlayMoveResignAndReview() throws {
        let app = XCUIApplication()
        app.launch()

        tapStartGame(in: app)

        // Play 1. e4 by tapping the pawn's square, then the target square.
        tapWhenReady(app.descendants(matching: .any)["square_e2"], "e2 square")
        tapWhenReady(app.descendants(matching: .any)["square_e4"], "e4 square")

        // Our move shows up in the move list.
        XCTAssertTrue(
            app.staticTexts["e4"].waitForExistence(timeout: Self.ciTimeout),
            "player move should be recorded"
        )

        endGame(in: app)

        // Open the review and wait for analysis to finish (engine-backed, so
        // slow runners need real headroom).
        tapWhenReady(app.buttons["Review Game"], "review button")
        XCTAssertTrue(
            app.staticTexts["White"].waitForExistence(timeout: 90),
            "review summary should appear"
        )
        tapWhenReady(app.buttons["Done"].firstMatch, "review done button")

        app.terminate()
    }

    @MainActor
    func testDragToMove() throws {
        let app = XCUIApplication()
        app.launch()

        tapStartGame(in: app)

        let e2 = app.descendants(matching: .any)["square_e2"]
        XCTAssertTrue(e2.waitForExistence(timeout: Self.ciTimeout), "board should appear")

        // Wait until the square is actually hittable: on slow CI simulators
        // the board can still be laying out when it first reports existence,
        // and a drag aimed at a moving frame misses.
        XCTAssertTrue(waitUntilHittable(e2, timeout: Self.ciTimeout), "square should become hittable")

        // Drag the e2 pawn to e4 instead of tapping. The long press and slow
        // velocity matter: the fast default delivers too few intermediate
        // touch events for SwiftUI's DragGesture on virtualized CI simulators.
        let e4 = app.descendants(matching: .any)["square_e4"]
        e2.press(forDuration: 0.5, thenDragTo: e4, withVelocity: .slow, thenHoldForDuration: 0.2)

        XCTAssertTrue(
            app.staticTexts["e4"].waitForExistence(timeout: Self.ciTimeout),
            "dragged move should be played"
        )

        // End the game before finishing. Leaving a live game keeps the engine
        // searching (and pondering) in the background, and on a slow CI VM
        // the compute-pegged process can't be terminated in time when the
        // next test launches — the "Failed to terminate" flake.
        endGame(in: app)
        app.terminate()
    }

    // MARK: - Helpers

    /// Resigns the current game and waits for the game-over sheet, so the
    /// test never abandons a live game with the engine still searching.
    /// Resign via the toolbar, then confirm in the dialog. The dialog adds a
    /// Cancel button plus a second "Resign"; tap the newest one.
    @MainActor
    private func endGame(in app: XCUIApplication) {
        let thinking = app.activityIndicators.firstMatch
        if thinking.exists {
            XCTAssertTrue(waitUntilGone(thinking, timeout: 60), "engine should finish thinking")
        }
        tapWhenReady(app.buttons["Resign"].firstMatch, "resign toolbar button")
        // The confirmation dialog adds a second "Resign" (its destructive
        // button). Wait on that, not on the auto-added "Cancel": iOS 26's
        // confirmationDialog no longer exposes a button labelled "Cancel" to
        // the accessibility tree, so keying on the dialog's own button is the
        // portable readiness signal across SDKs.
        let resignButtons = app.buttons.matching(NSPredicate(format: "label == 'Resign'"))
        let dialogOpen = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count >= 2"), object: resignButtons
        )
        XCTAssertEqual(XCTWaiter().wait(for: [dialogOpen], timeout: Self.ciTimeout), .completed,
                       "resign confirmation dialog should appear")
        resignButtons.allElementsBoundByIndex.last?.tap()
        XCTAssertTrue(
            app.staticTexts["You Lost"].waitForExistence(timeout: Self.ciTimeout),
            "game over sheet should appear"
        )
    }

    /// The home screen's List has grown past one screenful (time controls,
    /// difficulty, resume banner), and row heights differ between toolchains —
    /// with Xcode 16's bordered buttons, "Start Game" can start below the
    /// fold. XCUITest doesn't auto-scroll, so swipe until it's hittable.
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

    /// Waits for the element to exist and be hittable, then taps it. A bare
    /// `tap()` right after a transition can race layout on cold simulators.
    private func tapWhenReady(
        _ element: XCUIElement, _ what: String,
        timeout: TimeInterval = GameFlowUITests.ciTimeout,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout),
                      "\(what) should exist", file: file, line: line)
        XCTAssertTrue(waitUntilHittable(element, timeout: timeout),
                      "\(what) should be hittable", file: file, line: line)
        element.tap()
    }

    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"), object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
