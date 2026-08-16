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

    /// Pre-existing defect logged in `docs/STATE_AUDIT.md`'s Cheers section: tapping
    /// `cheers-toggle` can spuriously flip that same post's `showingComments` to `true`,
    /// opening `PostCommentsSheet` on top of the feed even though the comments button was never
    /// touched. Confirmed not self-correcting (it doesn't un-present on its own after several
    /// seconds with no alert in the picture), and confirmed to reproduce identically against the
    /// original `.alert`-based code, before the alert's own ~0.5s presentation delay had a chance
    /// to force-dismiss the wrongly-opened sheet.
    ///
    /// Uses the same fault-injected `toggleCheers` failure the alert investigation used — that's
    /// what makes this reliably reproducible rather than probabilistic: it forces
    /// `FeedViewModel.toggleCheers`'s state mutation to land on the very next run loop turn after
    /// the tap. No `sleep`/`Task.sleep` appears here or in the app: `tap()` already synchronizes
    /// with the app's run loop before returning to this test, so the defect, when present, is
    /// already observable the instant `tap()` returns — nothing here waits for it.
    @MainActor
    func testFeedCheersToggleDoesNotOpenCommentsSheet() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestDemo", "-uiTestFailOperation", "toggleCheers", "-uiTestFailError", "offline"]
        app.launch()
        app.tabBars.buttons["Feed"].tap()

        let cheers = app.buttons.matching(identifier: "cheers-toggle").firstMatch
        XCTAssertTrue(cheers.waitForExistence(timeout: 10), "each post needs a Cheers control")
        cheers.tap()

        XCTAssertFalse(app.navigationBars["Comments"].exists,
                        "tapping Cheers must not spuriously open that post's comments sheet")
    }

    /// The photo is a **third** tappable control added to `FeedPostCard`'s List row, alongside the
    /// Cheers toggle and the comments button — see `docs/STATE_AUDIT.md` and the two tests above
    /// for the real defect already found once in this exact row: a plain, un-styled `Button`
    /// letting `List`'s hit-testing route a tap to the wrong sibling control. This proves the new
    /// control doesn't reopen that failure mode: tapping Barnaby's seeded photo must open
    /// `PhotoViewerView` and *only* that — not fire Cheers, not open Comments, not trigger the
    /// post's overflow menu — and, the other direction, that the pre-existing Cheers/Comments
    /// controls still do exactly what they did before this card grew a photo tap target.
    @MainActor
    func testFeedPhotoTapOpensViewerWithoutMisroutingOtherControls() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestDemo"]
        app.launch()
        app.tabBars.buttons["Feed"].tap()

        // Barnaby's is the only seeded post with a photo (`DemoWorld.swift`), so this predicate
        // matches exactly one control; its identifier is suffixed with the post's UUID, which a
        // UI test has no way to predict, hence the prefix match rather than a literal string.
        let photo = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'feed-post-photo-'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10), "Barnaby's seeded photo post needs a tappable photo")

        let cheersBefore = app.buttons.matching(identifier: "cheers-toggle").element(boundBy: 1).label

        photo.tap()

        XCTAssertTrue(app.buttons["photo-viewer-close"].waitForExistence(timeout: 10),
                      "tapping the photo should open PhotoViewerView, reachable via its close control")
        XCTAssertFalse(app.navigationBars["Comments"].exists,
                        "tapping the photo must not spuriously open that post's comments sheet")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'post-report-'")).firstMatch.exists,
                        "tapping the photo must not spuriously open the post's overflow menu")
        XCTAssertEqual(app.buttons.matching(identifier: "cheers-toggle").element(boundBy: 1).label, cheersBefore,
                       "tapping the photo must not spuriously toggle Cheers")

        app.buttons["photo-viewer-close"].tap()
        XCTAssertTrue(app.buttons["photo-viewer-close"].waitForNonExistence(timeout: 5),
                      "the close control should dismiss the viewer")

        // The other direction: the pre-existing controls in this same row must still behave
        // exactly as they did before the photo gained a tap target.
        let cheers = app.buttons.matching(identifier: "cheers-toggle").element(boundBy: 1)
        XCTAssertTrue(cheers.waitForExistence(timeout: 10))
        let beforeToggle = cheers.label
        cheers.tap()
        XCTAssertNotEqual(cheers.label, beforeToggle,
                          "the Cheers toggle must still work after the photo gained a tap target")
        XCTAssertFalse(app.navigationBars["Comments"].exists,
                        "Cheers must still not spuriously open Comments")

        app.buttons.matching(identifier: "post-comments-button").firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Comments"].waitForExistence(timeout: 10),
                      "the comments button must still open the comments sheet")
    }
}
