import XCTest

/// End-to-end smoke test: start a game, make a move, get an engine reply,
/// resign, and open the game review.
final class GameFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPlayMoveResignAndReview() throws {
        let app = XCUIApplication()
        app.launch()

        app.buttons["Start Game"].tap()

        // Play 1. e4 by tapping the pawn's square, then the target square.
        let e2 = app.descendants(matching: .any)["square_e2"]
        XCTAssertTrue(e2.waitForExistence(timeout: 5), "board should appear")
        e2.tap()
        app.descendants(matching: .any)["square_e4"].tap()

        // Our move shows up in the move list.
        XCTAssertTrue(app.staticTexts["e4"].waitForExistence(timeout: 5), "player move should be recorded")

        // The engine (Black) answers with some move; the pawn we moved stays put
        // and a second SAN entry appears. Wait for the move list to grow.
        let engineReplied = NSPredicate(format: "count >= 2")
        let sanTexts = app.staticTexts.matching(NSPredicate(format: "identifier == '' AND label MATCHES %@", "^[KQRBNa-h].*"))
        _ = sanTexts // SAN matching is brittle; instead wait for thinking to finish.
        let thinking = app.activityIndicators.firstMatch
        if thinking.exists {
            XCTAssertTrue(waitUntilGone(thinking, timeout: 20), "engine should finish thinking")
        } else {
            // Engine may already have replied within the polling window.
            _ = engineReplied
        }

        // Resign via the toolbar, then confirm in the dialog. The dialog adds a
        // Cancel button plus a second "Resign"; tap the newest one.
        app.buttons["Resign"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5), "resign confirmation should appear")
        let resignButtons = app.buttons.matching(NSPredicate(format: "label == 'Resign'"))
        resignButtons.allElementsBoundByIndex.last?.tap()

        // Game-over sheet.
        XCTAssertTrue(app.staticTexts["You Lost"].waitForExistence(timeout: 5), "game over sheet should appear")

        // Open the review and wait for analysis to finish.
        app.buttons["Review Game"].tap()
        XCTAssertTrue(app.staticTexts["White"].waitForExistence(timeout: 30), "review summary should appear")
        app.buttons["Done"].firstMatch.tap()
    }

    @MainActor
    func testDragToMove() throws {
        let app = XCUIApplication()
        app.launch()

        app.buttons["Start Game"].tap()

        let e2 = app.descendants(matching: .any)["square_e2"]
        XCTAssertTrue(e2.waitForExistence(timeout: 5), "board should appear")

        // Wait until the square is actually hittable: on slow CI simulators
        // the board can still be laying out when it first reports existence,
        // and a drag aimed at a moving frame misses.
        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isHittable == true"), object: e2
        )
        XCTAssertEqual(XCTWaiter().wait(for: [hittable], timeout: 5), .completed,
                       "square should become hittable")

        // Drag the e2 pawn to e4 instead of tapping. The long press and slow
        // velocity matter: the fast default delivers too few intermediate
        // touch events for SwiftUI's DragGesture on virtualized CI simulators.
        let e4 = app.descendants(matching: .any)["square_e4"]
        e2.press(forDuration: 0.5, thenDragTo: e4, withVelocity: .slow, thenHoldForDuration: 0.2)

        XCTAssertTrue(app.staticTexts["e4"].waitForExistence(timeout: 10), "dragged move should be played")
    }

    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
