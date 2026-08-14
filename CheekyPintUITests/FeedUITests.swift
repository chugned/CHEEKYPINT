import XCTest

/// The Feed tab (master prompt feed client, part 1). Runs against demo mode (`-uiTestDemo`),
/// which needs no database — see `DemoWorld.activate` for the seeded posts these tests assert on.
final class FeedUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testFeedTabShowsSeededDemoPosts() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestDemo"]
        app.launch()

        let feedTab = app.tabBars.buttons["Feed"]
        XCTAssertTrue(feedTab.waitForExistence(timeout: 10), "the app should have a Feed tab")
        feedTab.tap()

        // DemoWorld seeds three posts; Alice's carries the place label "The Kings Arms, London"
        // (not "Prague" — see the report for where the brief's guess diverged from the real seed).
        XCTAssertTrue(app.staticTexts["The Kings Arms, London"].waitForExistence(timeout: 10),
                      "the seeded post's place label should render")
    }

    @MainActor
    func testCheersToggleUpdatesItsLabel() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestDemo"]
        app.launch()
        app.tabBars.buttons["Feed"].tap()

        let cheers = app.buttons.matching(identifier: "cheers-toggle").firstMatch
        XCTAssertTrue(cheers.waitForExistence(timeout: 10), "each post needs a Cheers control")
        let before = cheers.label
        cheers.tap()
        // The label carries the count, so it must change when toggled.
        XCTAssertTrue(cheers.waitForNonExistence(timeout: 0.1) == false)
        XCTAssertNotEqual(cheers.label, before, "toggling Cheers should change the control's label")
    }

    /// `docs/STATE_AUDIT.md`'s High finding: `FeedViewModel.toggleCheers` set `cheersError`
    /// correctly on every failure, but `FeedView` used to attach two separate boolean-driven
    /// `.alert` modifiers to the same view (one for `cheersError`, one for `deleteError`) — a
    /// conflict SwiftUI does not resolve reliably, so the Cheers alert never actually presented and
    /// a failed tap read as an unexplained flip-and-revert. Fixed by collapsing both into one
    /// `.alert` keyed on an enum (`FeedAlert` in `FeedView.swift`).
    ///
    /// Targets Barnaby's post (the *second* seeded post, `cheers-toggle` index 1), not Alice's
    /// (index 0, already seeded at "2 Cheers") — Alice's rollback lands back on the same "2
    /// Cheers" the seed already showed, which the audit noted could look like nothing happened
    /// even with a correct rollback. Barnaby's starts at zero/uncheered, so any lingering optimistic
    /// flip would be visibly wrong, not coincidentally identical to the untouched state.
    @MainActor
    func testFeedCheersErrorAlertPresents() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestDemo", "-uiTestFailOperation", "toggleCheers", "-uiTestFailError", "offline"]
        app.launch()
        app.tabBars.buttons["Feed"].tap()

        let cheers = app.buttons.matching(identifier: "cheers-toggle").element(boundBy: 1)
        XCTAssertTrue(cheers.waitForExistence(timeout: 10), "Barnaby's post needs a Cheers control")
        cheers.tap()

        let alert = app.alerts["Couldn't update Cheers"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10),
                      "a failed Cheers toggle must surface an alert naming the failure, not a silent flip-and-revert")
        XCTAssertTrue(alert.staticTexts["You're offline. We'll try again when you're back."].exists,
                      "the alert must carry the friendly, honest offline copy FeedViewModel set on cheersError")

        alert.buttons["OK"].tap()
        XCTAssertFalse(alert.exists, "OK must dismiss the alert")
        XCTAssertTrue(cheers.isEnabled, "the row must stay usable after the alert is dismissed")
    }
}
