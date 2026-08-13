import XCTest

/// Core UI flows (master prompt §24). These run on a simulator in Xcode/CI. They assume a
/// Development build pointed at a local Supabase with seed data. Extend with the log/undo,
/// add-friend, and privacy flows as screens stabilise.
final class OnboardingUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testWelcomeShowsResponsibleUseAndAgeGate() throws {
        let app = XCUIApplication()
        app.launch()

        // Responsible-use and age confirmation both have to be cleared before any auth control is
        // reachable. That means walking the flow: the age toggle lives on the THIRD screen, so an
        // assertion made on the welcome screen can never see it. The previous version of this test
        // waited for the toggle here and wrapped the §17 assertion in `if
        // ageToggle.waitForExistence`, so the condition was always false and the assertion never
        // ran at all — it was dead code that looked like coverage.
        let welcomeCTA = app.buttons["Pull up a stool"]
        XCTAssertTrue(welcomeCTA.waitForExistence(timeout: 10), "welcome screen never appeared")
        welcomeCTA.tap()

        // Screen 2: responsible use. Gate on its own control rather than body copy, which is the
        // kind of string that gets reworded without anyone thinking about the test.
        let responsibleCTA = app.buttons["Makes sense"]
        XCTAssertTrue(responsibleCTA.waitForExistence(timeout: 10), "responsible-use screen never appeared")
        responsibleCTA.tap()

        // Screen 3: the age gate. Unconditional now.
        let ageToggle = app.switches["ageConfirmationToggle"]
        XCTAssertTrue(ageToggle.waitForExistence(timeout: 10), "age gate never appeared")
        XCTAssertEqual(ageToggle.value as? String, "0",
                       "Age confirmation must not be pre-checked (master prompt §17)")

        // The gate's whole purpose is to block progress until the person confirms, and nothing
        // tested that. For an alcohol app this is the assertion that actually matters.
        let advance = app.buttons["Continue"]
        XCTAssertTrue(advance.exists, "age screen must offer a way forward")
        XCTAssertFalse(advance.isEnabled, "Continue must stay disabled until age is confirmed")

        // Tap the switch control itself, not the row. The identifier sits on the whole `Toggle`,
        // which is ~322pt wide with its label on the leading side and the switch on the trailing
        // side, so a plain `ageToggle.tap()` lands on the label/padding and does not flip anything.
        // Verified empirically: a centre tap leaves the value at "0", while tapping the switch
        // moves it to "1" and enables Continue. The nested element is the real UISwitch.
        ageToggle.switches.firstMatch.tap()
        XCTAssertEqual(ageToggle.value as? String, "1", "tapping the switch must confirm age")
        XCTAssertTrue(advance.isEnabled, "Continue must unlock once age is confirmed")
    }

    @MainActor
    func testCanNudgeBackFromLeaderboard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestDemo"]
        app.launch()

        let leaderboardTab = app.tabBars.buttons["Leaderboard"]
        XCTAssertTrue(leaderboardTab.waitForExistence(timeout: 10))
        leaderboardTab.tap()

        let nudgeBack = app.buttons["Nudge back"]
        XCTAssertTrue(nudgeBack.waitForExistence(timeout: 10))
        nudgeBack.tap()

        XCTAssertTrue(app.staticTexts["Nudge sent to Barnaby"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Sent"].exists)
    }
}
