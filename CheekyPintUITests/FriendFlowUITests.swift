import XCTest

/// The friend flow, end to end, through the app's own UI and against a real backend.
///
/// Two accounts are created from scratch on the local Supabase stack — real `/otp`, real codes
/// read out of the Mailpit inbox `supabase start` runs on :54324, real `regenerate_friend_token`,
/// `resolve_friend_token`, `send_friend_request`, `respond_to_friend_request`, `get_friends`,
/// `create_post` and `feed_page`. Nothing here is stubbed and `DemoWorld` is never activated: the
/// name B reads off the resolved code is the `display_name` A typed into profile setup, and the
/// post B eventually sees in its feed is the row A's own composer inserted.
///
/// **Why this test exists.** `FriendsView`, `AddFriendView` and `MyQRView` had no entry point in
/// the app shell until `0d37a23`, so the whole friend surface — and everything friendship gates
/// (the friends-only feed, the friend leaderboard, @mention autocomplete) — had never been
/// executed by anyone. `FriendsUITests` reaches the three screens, but does it in demo mode, where
/// `FriendsRepository` short-circuits every method to local fixtures and no request, acceptance or
/// friendship ever reaches a database.
///
/// **What makes the friendship assertion real.** "No error appeared" is not evidence. The gate is
/// `FriendsView`'s own empty-state placeholder, which renders exactly when `get_friends()` came
/// back with zero rows: it must be present before the accept and gone after it, on *both*
/// accounts. And the feed is asserted in both directions — A's post is absent from B's feed while
/// the request is merely pending, and present once it is accepted.
///
/// **Isolation from the offline suites.** Two levels. The whole case skips (loudly) when the local
/// stack isn't answering, like `OnboardingUITests`' own live cases — a developer without
/// `supabase start` gets a skip, not a hang. And the app is launched with
/// `-uiTestKeychainService`, so the real sessions this test creates land in a per-run Keychain
/// service instead of `app.cheekypint.session`; `OnboardingUITests` expects the welcome screen and
/// would launch straight into `MainTabView` if this test left a session behind (see
/// `AppContainer.launchKeychain()`).
///
/// **On the two sign-ins per address.** GoTrue's `max_frequency` (`supabase/config.toml`, 60s)
/// refuses a second code for an address inside a minute — but it keeps *two* timers, and a brand-
/// new address's first code is a signup confirmation while the next one, to the now-confirmed
/// user, is a magic link checked against a different, still-empty timer. So each account can sign
/// in exactly twice back to back, which is exactly what A → B → A → B needs. A *third* send to
/// either address inside a minute would be refused, which is why nothing here signs in again.
@MainActor
final class FriendFlowUITests: XCTestCase {

    private let app = XCUIApplication()

    /// Per-run identity. Every address, display name and post body carries it, so no assertion
    /// here can be satisfied by a row an earlier run left in the database.
    private let runID = String(UUID().uuidString.prefix(8))

    private var addressA: String { "cheekypint-friend-a-\(runID.lowercased())@example.com" }
    private var addressB: String { "cheekypint-friend-b-\(runID.lowercased())@example.com" }
    /// Single words, already capitalised: the display-name field is `.textInputAutocapitalization
    /// (.words)`, and `completeProfileSetup` asserts the field received exactly what was typed.
    private var nameA: String { "Ada\(runID)" }
    private var nameB: String { "Bram\(runID)" }
    private var postBody: String { "Pint \(runID) on the bar" }

    private static let noMatesPlaceholder = "No mates yet. Tap + to share your code."
    private static let emptyFeedTitle = "Nothing here yet"

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(LiveStack.isUp(),
                          "this signs two real users in against 127.0.0.1:54321 and reads their " +
                          "codes out of Mailpit on :54324 — run `supabase start`")
        app.launchArguments = ["-uiTestKeychainService", "app.cheekypint.uitests.\(runID)"]
    }

    // MARK: - The flow

    func testTwoStrangersBecomeMatesAndTheFriendsOnlyFeedOpensUp() throws {
        app.launch()

        // ─── A, first session: sign up, post, take the friend code ──────────────────────────
        try signIn(as: addressA)
        completeProfileSetup(named: nameA)

        composePost(postBody)
        // A's own post, in A's own feed. `feed_page`'s visibility arm is
        // `author_id = auth.uid() or is_accepted_friend(...)`, so this half needs no friendship —
        // but it does prove `create_post` inserted a row that `feed_page` will actually serve,
        // which is what makes B's two feed assertions below mean something.
        XCTAssertTrue(app.staticTexts[postBody].waitForExistence(timeout: 30),
                      "A's own post never came back from feed_page — create_post either failed " +
                      "silently or wrote something feed_page won't serve, and every feed " +
                      "assertion below would then be about a post that does not exist")

        openTab("Friends")
        XCTAssertTrue(app.navigationBars["Friends"].waitForExistence(timeout: 30),
                      "the Friends tab must open FriendsView")
        XCTAssertTrue(app.staticTexts[Self.noMatesPlaceholder].waitForExistence(timeout: 30),
                      "a brand-new account must start with an empty get_friends()")

        openMyQRAndCopyTheCode()
        signOut()

        // ─── B, first session: the feed is shut, then the request goes out ──────────────────
        try signIn(as: addressB)
        completeProfileSetup(named: nameB)

        // The negative half of the feed gate, and the half that makes the positive one worth
        // anything. Gated on the empty-state title, not merely on the post's absence: that title
        // renders only when the load finished, succeeded, and returned nothing, so this cannot
        // pass because the feed was still spinning or had errored out.
        openTab("Feed")
        XCTAssertTrue(app.staticTexts[Self.emptyFeedTitle].waitForExistence(timeout: 30),
                      "B's feed must load and be empty — B has no friends yet")
        XCTAssertFalse(app.staticTexts[postBody].exists,
                       "B can see a stranger's post. The feed is friends-only (feed_page's " +
                       "`is_accepted_friend` arm) and B has sent nothing yet")
        snap("31-b-feed-before-friendship")

        openTab("Friends")
        let code = pasteTheCopiedFriendCodeIntoAddAMate()
        // The placeholder check first, and it is not decoration: XCUITest reports a `UITextField`'s
        // *placeholder* as its `value` when the field is empty, so "Paste a friend code or link"
        // is 27 characters long and would satisfy the length check below on its own. Without this,
        // a paste that silently did nothing would sail past both.
        XCTAssertNotEqual(code, "Paste a friend code or link",
                          "the field is still empty — that string is the placeholder XCUITest " +
                          "hands back when nothing was pasted, so 'Copy code' put nothing on the " +
                          "pasteboard or the Paste item missed")
        XCTAssertGreaterThanOrEqual(code.count, 16,
                                    "nothing usable came off the pasteboard — " +
                                    "FriendToken.init?(rawValue:) rejects anything under 16 " +
                                    "characters. Got \(code.count): '\(code)'")
        app.buttons["Find friend"].tap()

        // resolve_friend_token, against a token minted minutes ago by the other account.
        XCTAssertTrue(app.staticTexts[nameA].waitForExistence(timeout: 30),
                      "the code did not resolve to A's real profile. FriendPreviewView shows " +
                      "\(nameA) only if resolve_friend_token returned the row behind the token " +
                      "A's My QR screen minted")
        snap("33-b-code-resolved-to-a")

        app.buttons["Send friend request"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 30),
                      "send_friend_request never reached its `.sent` phase — the Done button and " +
                      "the 'Request sent' label only render once the RPC returned")
        XCTAssertTrue(app.staticTexts["Request sent"].exists)
        app.buttons["Done"].tap()

        // Back out to the Friends list, which is where a user goes next anyway — and, less
        // obviously, the only thing that ends the manual-code field's keyboard. Dismissing the
        // preview sheet restores focus to that field, and its keyboard covers the tab bar
        // (keyboard {{0,583},{402,233}} over the Settings tab at {{303,795},{74,54}}), so the very
        // next `openTab` computed a hit point of {-1,-1} and tapped nothing at all.
        XCTAssertTrue(app.navigationBars["Add a mate"].waitForExistence(timeout: 20),
                      "Done must dismiss the preview back to Add a mate")
        app.navigationBars["Add a mate"].buttons["BackButton"].tap()
        XCTAssertTrue(app.navigationBars["Friends"].waitForExistence(timeout: 20),
                      "back from Add a mate must return to the Friends list")
        signOut()

        // ─── A, second session: accept ──────────────────────────────────────────────────────
        try signIn(as: addressA)
        openTab("Friends")

        let accept = app.buttons["Accept \(nameB)"]
        XCTAssertTrue(accept.waitForExistence(timeout: 30),
                      "get_pending_requests must return B's request to A")
        XCTAssertTrue(app.staticTexts[Self.noMatesPlaceholder].exists,
                      "a pending request is not a friendship — get_friends must still be empty " +
                      "on A's side until the accept")
        snap("34-a-request-pending")

        accept.tap()

        // THE assertion. `FriendsViewModel.respond` re-runs `load()` after the RPC, so the
        // placeholder disappearing means `get_friends()` genuinely returned a row — not that a
        // button was tapped and no error was shown. `FriendsViewModel.respond` swallows its error
        // with `try?`, so a failed accept looks exactly like a successful one on screen; this is
        // the only thing that can tell them apart.
        XCTAssertTrue(app.staticTexts[Self.noMatesPlaceholder].waitForNonExistence(timeout: 30),
                      "A's Mates section is still showing its empty-state placeholder after " +
                      "accepting, so respond_to_friend_request did not produce a friendship " +
                      "get_friends() can see")
        XCTAssertTrue(app.staticTexts[nameB].exists, "A's Mates section must now list \(nameB)")
        XCTAssertFalse(app.buttons["Accept \(nameB)"].exists,
                       "an accepted request must leave the Requests section")
        snap("35-a-friends-after-accept")
        signOut()

        // ─── B, second session: the other side of the friendship, and the feed it opens ─────
        try signIn(as: addressB)
        openTab("Friends")
        XCTAssertTrue(app.staticTexts[nameA].waitForExistence(timeout: 30),
                      "B's own get_friends() must return A. A friendship only one side can see " +
                      "is not a friendship — it would gate the feed, the leaderboard and mention " +
                      "autocomplete in one direction only")
        XCTAssertFalse(app.staticTexts[Self.noMatesPlaceholder].exists,
                       "B's Mates section is still showing its empty-state placeholder")
        snap("36-b-friends-after-accept")

        // The positive half of the feed gate: the same post, the same account, the same screen
        // that showed the empty state before the accept.
        openTab("Feed")
        XCTAssertTrue(app.staticTexts[postBody].waitForExistence(timeout: 30),
                      "A's post is still not in B's feed after the friendship was accepted — " +
                      "feed_page's `is_accepted_friend` arm is not seeing it, so the friendship " +
                      "exists in get_friends but does nothing")
        XCTAssertFalse(app.staticTexts[Self.emptyFeedTitle].exists,
                       "the empty state must be gone once there is a post to show")
        snap("37-b-feed-after-friendship")

        // Leaves the app signed out. Belt and braces on top of the per-run Keychain service: the
        // next suite to launch this app must find the welcome screen.
        signOut()
    }

    // MARK: - Screens

    /// Welcome → responsible use → age gate → email → the code Supabase actually emailed.
    /// Deliberately says nothing about where it lands: a new address lands on profile setup, a
    /// returning one straight in `MainTabView`, and both callers assert that themselves.
    private func signIn(as address: String) throws {
        let welcome = app.buttons["Pull up a stool"]
        XCTAssertTrue(welcome.waitForExistence(timeout: 30),
                      "expected the signed-out welcome screen before signing in as \(address)")
        welcome.tap()
        let responsible = app.buttons["Makes sense"]
        XCTAssertTrue(responsible.waitForExistence(timeout: 20), "responsible-use screen never appeared")
        responsible.tap()
        // The nested switch, not the row: the identifier sits on the whole `Toggle`, and a centre
        // tap lands on its label. See `OnboardingUITests`' own note.
        let ageToggle = app.switches["ageConfirmationToggle"]
        XCTAssertTrue(ageToggle.waitForExistence(timeout: 20), "age gate never appeared")
        ageToggle.switches.firstMatch.tap()
        XCTAssertEqual(ageToggle.value as? String, "1", "the age gate must actually confirm")
        app.buttons["Continue"].tap()

        let emailField = app.textFields["auth-email-field"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 20), "the email step never appeared")
        emailField.tap()
        emailField.typeText(address)
        app.buttons["auth-send-code"].tap()

        let codeField = app.textFields["auth-code-field"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 30),
                      "GoTrue would not send a code to \(address). If this is the third send to " +
                      "that address inside a minute, `max_frequency` in supabase/config.toml " +
                      "refused it — see this class's doc on why two is the budget")
        let code = try LiveStack.latestEmailedCode(sentTo: address)
        XCTAssertEqual(code.count, 6,
                       "Supabase emailed '\(code)', which is not a six-digit code — check " +
                       "supabase/templates/*.html still render {{ .Token }}")
        codeField.tap()
        codeField.typeText(code)
        app.buttons["auth-verify-code"].tap()
    }

    /// Name → photo → city → privacy → "Start pouring". Each step is gated on a control that only
    /// that step renders, so nothing here can tap ahead of the view.
    private func completeProfileSetup(named name: String) {
        let nameField = app.textFields["profile-setup-display-name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 30),
                      "verifying the emailed code must land a brand-new user on profile setup")
        nameField.tap()
        nameField.typeText(name)
        XCTAssertEqual(nameField.value as? String, name,
                       "the display-name field did not receive what was typed, so every later " +
                       "assertion on '\(name)' would be about the wrong string")

        let next = app.buttons["profile-setup-next"]
        next.tap()
        XCTAssertTrue(app.buttons["Choose photo"].waitForExistence(timeout: 20), "photo step")
        next.tap()
        XCTAssertTrue(app.textFields["profile-setup-city"].waitForExistence(timeout: 20), "city step")
        next.tap()
        XCTAssertTrue(app.staticTexts["Only accepted friends can ever see your details. You're in charge."]
                        .waitForExistence(timeout: 20), "privacy step")
        next.tap()

        XCTAssertTrue(app.tabBars.buttons["Friends"].waitForExistence(timeout: 30),
                      "'Start pouring' must write the profile (and legal_age_confirmed_at, which " +
                      "is the .onboarding → .ready gate) and reach MainTabView")
    }

    private func composePost(_ body: String) {
        openTab("Feed")
        let compose = app.buttons["feed-compose"]
        XCTAssertTrue(compose.waitForExistence(timeout: 30), "the Feed needs a composer")
        compose.tap()

        // `TextField(..., axis: .vertical)` is reported as a text *view*, not a text field, so the
        // query matches on the identifier across both types rather than guessing.
        let field = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ AND (elementType == %d OR elementType == %d)",
                        "compose-post-body",
                        XCUIElement.ElementType.textField.rawValue,
                        XCUIElement.ElementType.textView.rawValue)).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "the composer needs a body field")
        field.tap()
        field.typeText(body)
        XCTAssertEqual(field.value as? String, body, "the composer did not receive what was typed")

        app.buttons["compose-post-submit"].tap()
        XCTAssertTrue(app.buttons["feed-compose"].waitForExistence(timeout: 30),
                      "a successful post dismisses the composer; if it stayed up, create_post " +
                      "failed and compose-post-error says why")
    }

    /// A's My QR screen, and the raw token onto the pasteboard. `MyQRView` renders the code
    /// truncated (`token.rawValue.prefix(10) + "…"`), so "Copy code" is the only way any other
    /// screen — or any test — can get the whole thing, which is exactly the path a real pair of
    /// users takes.
    private func openMyQRAndCopyTheCode() {
        let myQR = app.buttons["My QR code"]
        XCTAssertTrue(myQR.waitForExistence(timeout: 20), "Friends needs a My QR control")
        myQR.tap()
        XCTAssertTrue(app.navigationBars["My QR"].waitForExistence(timeout: 20), "My QR should open MyQRView")

        let copy = app.buttons["Copy code"]
        XCTAssertTrue(copy.waitForExistence(timeout: 30),
                      "MyQRView never resolved a code. 'Copy code' renders only once " +
                      "regenerate_friend_token() returned; a spinner or a StatusView here means " +
                      "the RPC is still running or failed")
        snap("30-a-my-qr")
        copy.tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Friends"].waitForExistence(timeout: 20),
                      "Done must dismiss the My QR sheet")
    }

    /// Add-a-mate, with A's code pasted in from the pasteboard rather than typed: the test never
    /// learns the token any way the app doesn't already offer a user. Returns what actually landed
    /// in the field so the caller can assert on it.
    private func pasteTheCopiedFriendCodeIntoAddAMate() -> String {
        let addFriend = app.buttons["Add a friend"]
        XCTAssertTrue(addFriend.waitForExistence(timeout: 20), "Friends needs an Add-a-friend control")
        addFriend.tap()
        XCTAssertTrue(app.navigationBars["Add a mate"].waitForExistence(timeout: 20),
                      "Add a friend should open AddFriendView")

        let field = app.textFields["Paste a friend code or link"]
        XCTAssertTrue(field.waitForExistence(timeout: 20), "Add a mate needs a manual-code field")
        field.tap()
        field.press(forDuration: 1.2)
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 20),
                      "no Paste item in the edit menu — the pasteboard is empty, which means " +
                      "MyQRView's 'Copy code' did not write the token")
        paste.tap()
        snap("32-b-add-a-mate-pasted")
        return (field.value as? String) ?? ""
    }

    private func openTab(_ name: String) {
        let tab = app.tabBars.buttons[name]
        XCTAssertTrue(tab.waitForExistence(timeout: 30), "the app should have a \(name) tab")
        tab.tap()
    }

    private func signOut() {
        openTab("Settings")
        let row = app.buttons["Sign out"]
        XCTAssertTrue(row.waitForExistence(timeout: 20), "Settings needs a Sign out control")
        row.tap()
        // `confirmationDialog` renders as an action sheet, whose own "Sign out" is a second
        // element with the same label — hence the `sheets` container rather than a bare lookup.
        let confirm = app.sheets.buttons["Sign out"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 20), "signing out must ask for confirmation")
        confirm.tap()
        XCTAssertTrue(app.buttons["Pull up a stool"].waitForExistence(timeout: 30),
                      "signing out must return to the welcome flow")
    }

    // MARK: - Screenshots

    private func snap(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// The local Supabase stack, reached over HTTP from the UI-test runner — the simulator shares the
/// host's network stack, so :54321 and :54324 are the same services the app itself is talking to.
///
/// Deliberately a separate copy of `EmailOTPAuthTests`' Mailpit reader rather than a shared one:
/// that lives in the unit-test bundle, which this bundle cannot import, and the alternative
/// (hoisting it into the app target) would ship mail-reading code in the product.
private enum LiveStack {
    static let auth = URL(string: "http://127.0.0.1:54321/auth/v1")!
    static let mailpit = URL(string: "http://127.0.0.1:54324")!

    /// A skip, not a silent pass: this case proves nothing at all without the stack it drives.
    static func isUp() -> Bool {
        reachable(auth.appendingPathComponent("health"))
            && reachable(mailpit.appendingPathComponent("api/v1/messages"))
    }

    /// The six-digit code from the newest message addressed to `email`.
    ///
    /// No polling and no waiting. GoTrue's local mailer hands the message to SMTP inside the
    /// `/otp` request, and the caller only gets here after the app's own code step appeared —
    /// which it does only once that request returned 200. The message is already in the inbox.
    static func latestEmailedCode(sentTo email: String) throws -> String {
        var components = URLComponents(url: mailpit.appendingPathComponent("api/v1/search"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "query", value: "to:\(email)")]
        let listing = try get(components.url!)
        let summaries = try JSONDecoder().decode(SearchResult.self, from: listing)
        guard let newest = summaries.messages.sorted(by: { $0.Created > $1.Created }).first else {
            throw MailpitError.noMessage(email)
        }
        let body = try get(mailpit.appendingPathComponent("api/v1/message/\(newest.ID)"))
        let message = try JSONDecoder().decode(Message.self, from: body)
        let text = message.Text ?? message.HTML ?? ""
        guard let range = text.range(of: "[0-9]{6}", options: .regularExpression) else {
            throw MailpitError.noCode(text)
        }
        return String(text[range])
    }

    // MARK: Plumbing

    private static func reachable(_ url: URL) -> Bool {
        guard let (_, response) = try? request(url), let http = response as? HTTPURLResponse else {
            return false
        }
        return (200..<300).contains(http.statusCode)
    }

    private static func get(_ url: URL) throws -> Data {
        let (data, response) = try request(url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MailpitError.badResponse(url, (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return data
    }

    /// XCTest's test methods are synchronous, so the async API isn't available here. Blocking on a
    /// semaphore is safe: `URLSession`'s completion runs on its own delegate queue, never on the
    /// thread being blocked.
    private static func request(_ url: URL) throws -> (Data, URLResponse) {
        var result: Result<(Data, URLResponse), Error>?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: url) { data, response, error in
            if let data, let response { result = .success((data, response)) }
            else { result = .failure(error ?? MailpitError.badResponse(url, -1)) }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 30)
        guard let result else { throw MailpitError.badResponse(url, -1) }
        return try result.get()
    }

    private struct SearchResult: Decodable { let messages: [Summary] }
    private struct Summary: Decodable { let ID: String; let Created: String }
    private struct Message: Decodable { let Text: String?; let HTML: String? }

    enum MailpitError: Error, CustomStringConvertible {
        case noMessage(String)
        case noCode(String)
        case badResponse(URL, Int)

        var description: String {
            switch self {
            case let .noMessage(email):
                return "Mailpit has no message for \(email) — GoTrue accepted the request but sent nothing"
            case let .noCode(body):
                return "no six-digit code in the email body. Check supabase/templates/*.html " +
                       "still render {{ .Token }}. Body was: \(body.prefix(300))"
            case let .badResponse(url, status):
                return "\(url) answered \(status)"
            }
        }
    }
}
