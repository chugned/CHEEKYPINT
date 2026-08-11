import XCTest

/// Drives the app and captures screenshots of the key screens. Launches once for the welcome
/// screen, then relaunches straight into demo mode (via the `-uiTestDemo` launch argument) so
/// navigation is deterministic. Best-effort (no hard asserts) so one missing control never
/// blocks the rest. A script exports the attachments into `screenshots/`.
@MainActor
final class ScreenshotTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    func testCaptureAppScreens() {
        // 1. Welcome (pre-auth), normal launch.
        app.launch()
        _ = app.staticTexts["Remember the good rounds"].waitForExistence(timeout: 8)
        sleep(1)
        snap("01-welcome")
        app.terminate()

        // Relaunch straight into the app with seeded demo data.
        app.launchArguments = ["-uiTestDemo"]
        app.launch()

        let logButton = app.buttons["Choose and log a beer"]
        XCTAssertTrue(logButton.waitForExistence(timeout: 15), "home should appear in demo mode")
        sleep(2)
        snap("02-home")

        // 3. Log / beer-picker sheet.
        logButton.tap()
        sleep(2)
        snap("03-log-sheet")
        tap("Cancel", timeout: 4)
        sleep(1)

        // 4. Full leaderboard.
        if tap("See full standings", timeout: 5) {
            sleep(2)
            snap("04-leaderboard")
            back()
            sleep(1)
        }

        // 5–7. Tabs.
        if tapTab("Friends") { sleep(2); snap("05-friends") }
        if tapTab("Pubs") { sleep(2); snap("06-pubs") }
        if tapTab("Profile") { sleep(2); snap("07-profile") }

        // 8. My diary (from Profile).
        if tap("My diary", timeout: 5) { sleep(2); snap("08-diary") }
    }

    // MARK: - Helpers

    private func snap(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @discardableResult
    private func tap(_ label: String, timeout: TimeInterval) -> Bool {
        let button = app.buttons[label]
        if button.waitForExistence(timeout: timeout) { button.tap(); return true }
        let any = app.descendants(matching: .any)[label]
        if any.waitForExistence(timeout: 1) { any.tap(); return true }
        return false
    }

    @discardableResult
    private func tapTab(_ label: String) -> Bool {
        let tab = app.tabBars.buttons[label]
        if tab.waitForExistence(timeout: 5) { tab.tap(); return true }
        return false
    }

    private func back() {
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        if backButton.exists { backButton.tap() }
    }
}
