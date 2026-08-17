import XCTest

/// The Friends tab. Before this test existed, `FriendsView`, `AddFriendView`, and `MyQRView` were
/// all fully built but had no path to them from `MainTabView` — nothing ever instantiated
/// `FriendsView` (the only references outside its own file were two code comments), so friend
/// management, and everything friendship gates (friends-only feed posts, the friend leaderboard,
/// @mention autocomplete), was unreachable. This drives the whole path a user actually takes.
///
/// Runs against demo mode (`-uiTestDemo`), which needs no database — `DemoWorld.activate` seeds
/// two mates (Barnaby, Ceri) and one pending request (Dev), so the list has real content to
/// assert on rather than only an empty state, and `regenerateFriendToken()` resolves locally
/// (`DemoWorld.newFriendToken()`), so My QR loads deterministically with no network involved.
final class FriendsUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    /// Reach the Friends tab, see the seeded list, open "Add a mate", back out, then open
    /// "My QR" and see it actually resolve to a code — the three destinations the brief named as
    /// unreachable, plus the tab itself.
    @MainActor
    func testFriendsTabReachesAddAMateAndMyQR() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestDemo"]
        app.launch()

        // 1. The tab exists at all. This is the actual gate for the whole feature: remove the
        // `FriendsView()` case from `MainTabView`'s `TabView` and this is the first assertion to
        // fail, before anything below it ever runs — proven by actually doing that (see the PR
        // notes / commit message for the verbatim failure this produced).
        let friendsTab = app.tabBars.buttons["Friends"]
        XCTAssertTrue(friendsTab.waitForExistence(timeout: 10), "the app should have a Friends tab")
        friendsTab.tap()

        // 2. The tab actually opens FriendsView, not an empty NavigationStack: its own
        // `.navigationTitle("Friends")` must appear, and the seeded mate "Barnaby" must render.
        // Flip point: fails if `FriendsViewModel.load()` never ran, or if `model` never got set,
        // since `list(_:)` (and therefore "Barnaby") only renders once `model` is non-nil.
        XCTAssertTrue(app.navigationBars["Friends"].waitForExistence(timeout: 10),
                      "tapping the Friends tab should open FriendsView")
        XCTAssertTrue(app.staticTexts["Barnaby"].waitForExistence(timeout: 10),
                      "the seeded mate should render in the Mates section")

        // 3. "Add a mate" — previously reachable from nowhere in the app shell (only from
        // `FriendsView`'s own toolbar, and nothing reached `FriendsView`). Flip point: fails if
        // the toolbar's `NavigationLink` to `AddFriendView` is missing or its destination broken.
        let addFriend = app.buttons["Add a friend"]
        XCTAssertTrue(addFriend.waitForExistence(timeout: 10), "Friends needs an Add-a-friend control")
        addFriend.tap()
        XCTAssertTrue(app.navigationBars["Add a mate"].waitForExistence(timeout: 10),
                      "Add a friend should open AddFriendView (\"Add a mate\")")

        // Back to Friends, so the next step starts from the same place a real user would.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Friends"].waitForExistence(timeout: 10),
                      "back from Add a mate should return to Friends")

        // 4. "My QR" — previously reachable only from the dead `ProfileView` (never instantiated
        // anywhere). Flip point for the first assertion: fails if the toolbar button or its sheet
        // is missing. Flip point for the second: fails if the sheet opens but
        // `regenerateFriendToken()` never resolves (stuck on `ProgressView`) or errors
        // (`StatusView` instead of the code) — "Copy code" only renders once a token loaded.
        let myQR = app.buttons["My QR code"]
        XCTAssertTrue(myQR.waitForExistence(timeout: 10), "Friends needs a My QR control")
        myQR.tap()
        XCTAssertTrue(app.navigationBars["My QR"].waitForExistence(timeout: 10),
                      "My QR should open MyQRView")
        XCTAssertTrue(app.buttons["Copy code"].waitForExistence(timeout: 10),
                      "MyQRView should resolve to a real code, not stay loading or errored")
    }

    /// After the friend-preview sheet is dismissed, the tab bar must still be tappable.
    ///
    /// Typing a code into `AddFriendView`'s manual field makes that `TextField` first responder.
    /// UIKit restores first responder when a modal it presented goes away, so dismissing the
    /// preview sheet used to bring the keyboard straight back up — over the tab bar. A tab button
    /// underneath the keyboard is present and `isHittable`-looking but computes a hit point of
    /// `{-1, -1}`, so `tap()` lands nowhere and the tab never changes. The user was stuck too.
    ///
    /// Demo mode is what makes this offline and quick: `FriendsRepository.resolveToken` short-
    /// circuits to a local fixture ("A new mate"), so the sheet presents with no network at all.
    /// The same state is reached against a real backend in `FriendFlowUITests`, which stopped
    /// needing its back-navigation workaround once this was fixed.
    @MainActor
    func testTabBarStaysTappableAfterTheFriendPreviewSheetIsDismissed() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestDemo"]
        app.launch()

        app.tabBars.buttons["Friends"].tap()
        let addFriend = app.buttons["Add a friend"]
        XCTAssertTrue(addFriend.waitForExistence(timeout: 10), "Friends needs an Add-a-friend control")
        addFriend.tap()

        // Typing, not pasting: it is the keyboard this raises that the bug was about.
        let field = app.textFields["Paste a friend code or link"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Add a mate needs a manual-code field")
        field.tap()
        // 32 base64url characters — `FriendToken.init?(rawValue:)` rejects anything shorter than
        // 16 or outside that alphabet, and `resolve(_:)` would then set `errorMessage` and never
        // present the sheet, so this test would pass without ever reaching the state it is about.
        let code = "AbCdEfGhIjKlMnOpQrStUvWxYz012345"
        field.typeText(code)
        XCTAssertEqual(field.value as? String, code,
                       "the manual-code field did not receive what was typed, so no keyboard was " +
                       "ever raised and this test would prove nothing")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10),
                      "typing into the manual-code field must raise a keyboard — without one " +
                      "there is nothing for the sheet's dismissal to restore and no bug to catch")

        app.buttons["Find friend"].tap()
        XCTAssertTrue(app.staticTexts["A new mate"].waitForExistence(timeout: 10),
                      "the code should resolve to DemoWorld's preview fixture")
        app.buttons["Close"].tap()
        XCTAssertTrue(app.staticTexts["A new mate"].waitForNonExistence(timeout: 10),
                      "Close must dismiss the friend-preview sheet")

        // The state the bug produced. Read this attachment: before the fix it shows the keyboard
        // sitting over the tab bar.
        snap("40-add-a-mate-after-preview-dismissed")

        // THE assertion. Not "the tab button exists" — it always did, keyboard or not. The tab
        // must actually become the selected one, which is exactly what a tap at {-1, -1} fails
        // to do.
        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 10), "the app should have a Settings tab")
        settingsTab.tap()
        XCTAssertTrue(settingsTab.wait(for: \.isSelected, toEqual: true, timeout: 10),
                      "tapping the Settings tab after dismissing the friend preview did not " +
                      "select it — the manual-code field's keyboard is back over the tab bar and " +
                      "the tap resolved to hit point {-1, -1}")
        // And the tab genuinely switched screens, not merely repainted its button.
        XCTAssertTrue(app.buttons["Sign out"].waitForExistence(timeout: 10),
                      "the Settings tab reported itself selected but SettingsView never appeared")
        snap("41-settings-tab-after-preview-dismissed")
    }

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
