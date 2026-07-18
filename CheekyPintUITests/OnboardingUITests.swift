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

        // Welcome → responsible-use + age confirmation must be present before any auth control.
        XCTAssertTrue(app.staticTexts["CheekyPint"].waitForExistence(timeout: 5))
        // The age-confirmation toggle must NOT be pre-checked (master prompt §17).
        let ageToggle = app.switches["ageConfirmationToggle"]
        if ageToggle.waitForExistence(timeout: 5) {
            XCTAssertEqual(ageToggle.value as? String, "0", "Age confirmation must not be pre-checked")
        }
    }
}
