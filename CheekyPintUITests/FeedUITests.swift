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
}
