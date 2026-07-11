import XCTest

/// On-demand accessibility audit (issue #83's evidence harness — not a CI
/// gate): runs Xcode's accessibility audit on the main screens, keeping the
/// findings and screenshots as attachments for
/// `xcrun xcresulttool export attachments`.
///
/// Run it explicitly:
///   TEST_RUNNER_RUN_A11Y_AUDIT=1 xcodebuild test … \
///     -only-testing:ios-chess-clientUITests/AccessibilityAuditTests
///
/// Skips itself otherwise, and CI's -only-testing selection never includes
/// it — findings are point-in-time evidence, not pass/fail regressions.
final class AccessibilityAuditTests: XCTestCase {
    private var report = ""

    @MainActor
    func testAuditHomeGameAndReview() throws {
        guard ProcessInfo.processInfo.environment["RUN_A11Y_AUDIT"] == "1" else {
            throw XCTSkip("on-demand audit: set TEST_RUNNER_RUN_A11Y_AUDIT=1 to run")
        }
        let app = XCUIApplication()
        app.launch()

        audit(app, screen: "home")
        attachScreenshot(app, name: "screen-home")

        // Engine game screen.
        app.buttons["Start Game"].tap()
        guard app.descendants(matching: .any)["square_e2"].waitForExistence(timeout: 10) else {
            attachReport(); return XCTFail("board did not appear")
        }
        audit(app, screen: "game")
        attachScreenshot(app, name: "screen-game")

        for square in ["square_e2", "square_e4", "square_a8"] {
            let el = app.descendants(matching: .any)[square]
            if el.exists {
                report += "SQUARE \(square): label='\(el.label)' hittable=\(el.isHittable)\n"
            }
        }
        report += "BUTTON-TREE[game]:\n\(app.buttons.debugDescription)\n"

        attachReport()
    }

    @MainActor
    private func audit(_ app: XCUIApplication, screen: String) {
        do {
            try app.performAccessibilityAudit(for: .all) { issue in
                let element = issue.element.map(String.init(describing:)) ?? "nil"
                self.report += "A11Y-ISSUE[\(screen)] \(issue.auditType): \(issue.compactDescription) | \(element)\n"
                return true
            }
            report += "AUDIT[\(screen)] completed\n"
        } catch {
            report += "AUDIT[\(screen)] threw: \(error)\n"
        }
    }

    private func attachReport() {
        let attachment = XCTAttachment(string: report)
        attachment.name = "a11y-report"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
