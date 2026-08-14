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
    /// correctly on every failure, but `FeedView`'s `.alert` for it never actually presented. The
    /// "two `.alert` modifiers conflict" hypothesis this test originally targeted turned out to be
    /// wrong — merging into one enum-keyed alert changed nothing. The real cause: a plain, un-menued
    /// `Button`'s directly-invoked, detached `Task` mutating alert-driving state doesn't give
    /// SwiftUI's modal-presentation machinery a native transition (a `Menu`/`confirmationDialog`,
    /// which the sibling delete-error alert has) to settle against first — see `FeedView.swift`'s
    /// `FeedAlert` doc for the elimination process. Rather than time around that with a wall-clock
    /// deferral (tried, worked, rejected as fragile — tuned to one machine on one day), the fix
    /// removes the failure mode: `cheersError` is now plain inline content
    /// (`accessibilityIdentifier("feed-cheers-error")`), matching how every other transient error in
    /// this app is reported. Inline content has no presentation step to race, so this needs no
    /// deferral and no `sleep`/`Task.sleep` to observe.
    ///
    /// Targets Barnaby's post (the *second* seeded post, `cheers-toggle` index 1), not Alice's
    /// (index 0, already seeded at "2 Cheers") — Alice's rollback lands back on the same "2
    /// Cheers" the seed already showed, which the audit noted could look like nothing happened
    /// even with a correct rollback. Barnaby's starts at zero/uncheered, so any lingering optimistic
    /// flip would be visibly wrong, not coincidentally identical to the untouched state.
    @MainActor
    func testFeedCheersErrorShowsInlineMessage() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestDemo", "-uiTestFailOperation", "toggleCheers", "-uiTestFailError", "offline"]
        app.launch()
        app.tabBars.buttons["Feed"].tap()

        let cheers = app.buttons.matching(identifier: "cheers-toggle").element(boundBy: 1)
        XCTAssertTrue(cheers.waitForExistence(timeout: 10), "Barnaby's post needs a Cheers control")
        cheers.tap()

        let errorText = app.staticTexts["feed-cheers-error"]
        XCTAssertTrue(errorText.waitForExistence(timeout: 10),
                      "a failed Cheers toggle must surface an inline message naming the failure, not a silent flip-and-revert")
        XCTAssertEqual(errorText.label, "You're offline. We'll try again when you're back.",
                       "the inline message must carry the friendly, honest offline copy FeedViewModel set on cheersError")
        XCTAssertTrue(cheers.isEnabled, "the row must stay usable while the error is shown")
    }
}
