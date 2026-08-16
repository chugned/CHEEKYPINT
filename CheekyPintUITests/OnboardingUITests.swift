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

    /// The real sign-in flow, driven through the UI against the local Supabase stack: email step →
    /// a code that Supabase genuinely emailed → the code step → a wrong code → the error.
    ///
    /// Screenshots are attached from each of the three states, because a passing UI test says
    /// nothing about whether the screen is readable — this project has shipped a card that
    /// overflowed the screen width and passed every test it had.
    @MainActor
    func testEmailCodeSignInReachesTheCodeStepAndNamesARejectedCode() throws {
        try XCTSkipUnless(Self.localStackIsUp(),
                          "this drives real GoTrue on 127.0.0.1:54321 — run `supabase start`")
        let app = XCUIApplication()
        app.launch()
        walkToAuth(app)

        let emailField = app.textFields["auth-email-field"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 10), "the email step never appeared")
        snap(app, "10-auth-email")

        emailField.tap()
        emailField.typeText(Self.uniqueAddress())
        app.buttons["auth-send-code"].tap()

        let codeField = app.textFields["auth-code-field"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 15),
                      "a successful send must advance to the code step")
        XCTAssertTrue(app.buttons["auth-resend-code"].exists, "the code step must offer a resend")
        XCTAssertTrue(app.buttons["auth-change-email"].exists,
                      "a mistyped address is the likeliest reason no code arrives, so there must " +
                      "be a way back to fix it")
        XCTAssertFalse(app.buttons["auth-resend-code"].isEnabled,
                       "resend starts locked — Supabase refuses a second send inside a minute")
        snap(app, "11-auth-code")

        codeField.tap()
        codeField.typeText("000000")
        app.buttons["auth-verify-code"].tap()

        let notice = app.staticTexts["auth-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 15), "a rejected code must say something")
        let text = notice.label
        XCTAssertNotEqual(text, "You don't have access to that.",
                          "a wrong code is not an access problem")
        XCTAssertNotEqual(text, "Something went wrong. Please try again.",
                          "the generic copy hides the one thing the user can act on")
        XCTAssertTrue(text.contains("mistyped"), "unexpected rejection copy: \(text)")

        // The label above is what XCUITest reports, and it is the *whole* string whether or not
        // the screen drew it — the first version of this view rendered it as one truncated line
        // ("…or past its ex…"), dropping the remedy, and every assertion above still passed.
        // Height is the only handle on what was actually laid out: `Theme.Typography.caption` is
        // ~12pt with a ~16pt line box, and this sentence is 118 characters, which cannot fit on
        // one line at any iPhone width. Flip point: put the `Label` back and this drops to ~16.
        XCTAssertGreaterThan(notice.frame.height, 24,
                             "the rejection message is being truncated to a single line — it is " +
                             "\(text.count) characters and rendered only \(notice.frame.height)pt tall")
        snap(app, "12-auth-code-error")
    }

    /// The same two screens at accessibility XXL. The assertion that matters is horizontal: the
    /// scaffold scrolls vertically now, so content below the fold is expected, but nothing may
    /// run off the side of the screen. `docs/ACCESSIBILITY_AUDIT.md` records real clipping found
    /// on this app's own surfaces at exactly this text size.
    @MainActor
    func testSignInStepsSurviveAccessibilityXXL() throws {
        try XCTSkipUnless(Self.localStackIsUp(),
                          "this drives real GoTrue on 127.0.0.1:54321 — run `supabase start`")
        let app = XCUIApplication()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXL"]
        app.launch()
        walkToAuth(app)

        let screen = app.windows.element(boundBy: 0).frame
        let emailField = app.textFields["auth-email-field"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 10))
        assertWithinWidth(emailField, screen, "auth-email-field")
        assertWithinWidth(app.buttons["auth-send-code"], screen, "auth-send-code")
        snap(app, "13-auth-email-xxl")

        emailField.tap()
        emailField.typeText(Self.uniqueAddress())
        app.buttons["auth-send-code"].tap()

        let codeField = app.textFields["auth-code-field"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 15))
        assertWithinWidth(codeField, screen, "auth-code-field")
        assertWithinWidth(app.buttons["auth-verify-code"], screen, "auth-verify-code")
        assertWithinWidth(app.buttons["auth-resend-code"], screen, "auth-resend-code")
        snap(app, "14-auth-code-xxl")
    }

    // MARK: Sign-in helpers

    /// Welcome → responsible use → age gate → sign in. The age toggle's own switch has to be
    /// tapped rather than the row (see the comment in the flow test above).
    @MainActor
    private func walkToAuth(_ app: XCUIApplication) {
        let welcomeCTA = app.buttons["Pull up a stool"]
        XCTAssertTrue(welcomeCTA.waitForExistence(timeout: 15), "welcome screen never appeared")
        welcomeCTA.tap()
        let responsibleCTA = app.buttons["Makes sense"]
        XCTAssertTrue(responsibleCTA.waitForExistence(timeout: 10))
        responsibleCTA.tap()
        let ageToggle = app.switches["ageConfirmationToggle"]
        XCTAssertTrue(ageToggle.waitForExistence(timeout: 10))
        ageToggle.switches.firstMatch.tap()
        app.buttons["Continue"].tap()
    }

    @MainActor
    private func assertWithinWidth(_ element: XCUIElement, _ screen: CGRect, _ name: String) {
        XCTAssertTrue(element.exists, "\(name) is missing at accessibility XXL")
        XCTAssertLessThanOrEqual(element.frame.maxX, screen.maxX + 0.5,
                                 "\(name) runs off the right of the screen at accessibility XXL " +
                                 "(\(element.frame) vs \(screen))")
        XCTAssertGreaterThanOrEqual(element.frame.minX, screen.minX - 0.5,
                                    "\(name) runs off the left of the screen at accessibility XXL")
    }

    @MainActor
    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A fresh address per run, so no send is ever refused for being inside the previous one's
    /// 60-second window.
    private static func uniqueAddress() -> String {
        "cheekypint-ui-\(UUID().uuidString.prefix(8).lowercased())@example.com"
    }

    /// A skip, not a silent pass: these two cases prove nothing without the stack they drive.
    private static func localStackIsUp() -> Bool {
        let url = URL(string: "http://127.0.0.1:54321/auth/v1/health")!
        var reachable = false
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: url) { _, response, _ in
            reachable = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 5)
        return reachable
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
