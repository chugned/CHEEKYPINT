import XCTest
import CheekyPintCore
@testable import CheekyPint

/// The email one-time-code sign-in, in two halves.
///
/// **`EmailCodeSignIn` on its own** — the resend cooldown, the input gates, and what each server
/// failure is allowed to tell the user. The clock is injected, so "the cooldown has 1 second left"
/// is a pure assertion about a `Date` argument rather than something a test has to wait for.
///
/// **Against a real GoTrue** — the whole flow, including the code, which is read out of the
/// Mailpit inbox that `supabase start` runs on :54324. Nothing is stubbed on that path: the code
/// asserted on is the one Supabase actually put in an email, and the profile asserted on is the
/// row `on_auth_user_created` actually inserted. Those cases skip (loudly) if the local stack
/// isn't up, and every one of them is a no-op without it — see `requireLocalStack`.
@MainActor
final class EmailOTPAuthTests: XCTestCase {

    // MARK: - The state machine, with no server anywhere near it

    /// The cooldown's two ends. Injected clock, so nothing sleeps: the flip point is
    /// `resendCooldown`, and setting it to 0 turns the "still locked at +59s" assertions false
    /// while leaving everything else about the flow working.
    func testResendIsLockedForTheWholeCooldownAndUnlocksAtItsEnd() async {
        let clock = TestClock()
        let spy = CallSpy()
        let model = makeModel(clock: clock, spy: spy)
        let start = clock.now

        model.emailInput = "nedim@example.com"
        await model.sendCode()

        XCTAssertEqual(model.step, .code, "a send that succeeded must advance to the code step")
        XCTAssertEqual(model.secondsUntilResend(now: start), 60,
                       "the cooldown starts at its full length the instant the code goes out")
        XCTAssertFalse(model.canResend(now: start.addingTimeInterval(59)),
                       "one second before the end is still inside the cooldown")
        XCTAssertEqual(model.secondsUntilResend(now: start.addingTimeInterval(59)), 1)
        XCTAssertTrue(model.canResend(now: start.addingTimeInterval(60)),
                      "the cooldown must actually end — a Resend that never unlocks strands " +
                      "anyone whose first email didn't arrive")

        // And the gate is load-bearing, not decorative: it must stop the call, not just grey out
        // a button that still fires.
        clock.now = start.addingTimeInterval(30)
        await model.resendCode()
        XCTAssertEqual(spy.sentTo.count, 1,
                       "a resend inside the cooldown must not reach the server — Supabase answers " +
                       "it with a 429 that costs the user their next send")

        clock.now = start.addingTimeInterval(60)
        await model.resendCode()
        XCTAssertEqual(spy.sentTo, ["nedim@example.com", "nedim@example.com"])
        XCTAssertEqual(model.notice, .codeSent(email: "nedim@example.com"),
                       "a resend with no visible confirmation reads as a dead button")
        XCTAssertEqual(model.secondsUntilResend(now: clock.now), 60, "the cooldown restarts")
    }

    /// The failure this whole error-mapping exercise exists for. Flip point: map through
    /// `SupabaseError.from` instead of `fromAuth` and the notice becomes
    /// "Something went wrong. Please try again." — which tells a throttled user nothing and
    /// invites the retry that extends the throttle.
    func testARateLimitedSendKeepsTheUserOnTheEmailStepAndSaysWhatActuallyHappened() async {
        let spy = CallSpy()
        // Verbatim from a real local GoTrue v2.195.0 429 body.
        spy.sendError = SupabaseError.rateLimited(
            hint: "For security purposes, you can only request this after 47 seconds.")
        let clock = TestClock()
        let model = makeModel(clock: clock, spy: spy)

        model.emailInput = "nedim@example.com"
        await model.sendCode()

        XCTAssertEqual(model.step, .email,
                       "no code went out, so the code step would be a screen asking for something " +
                       "that does not exist")
        guard case let .sendThrottled(sentence) = model.notice else {
            return XCTFail("expected a throttle notice, got \(String(describing: model.notice))")
        }
        XCTAssertEqual(sentence, "For security purposes, you can only request this after 47 seconds.")
        XCTAssertTrue(model.notice?.text.contains("47 seconds") == true,
                      "the remaining wait exists only in the server's sentence — paraphrasing it " +
                      "throws away the one number the user needs")
        XCTAssertFalse(model.notice?.text.contains("Something went wrong") == true)
        XCTAssertEqual(model.secondsUntilResend(now: clock.now), 60,
                       "a 429 is the server saying it will refuse again; Resend must lock too")
    }

    /// Flip point: delete the `isPlausible` guard and `sentTo` records one call, spending one of
    /// a hard-limited quota of sends on an address that cannot receive anything.
    func testAnImplausibleAddressNeverSpendsARequest() async {
        let spy = CallSpy()
        let model = makeModel(clock: TestClock(), spy: spy)

        model.emailInput = "nedim.example.com"
        await model.sendCode()

        XCTAssertEqual(spy.sentTo, [], "an address with no @ can only come back as a 400")
        XCTAssertEqual(model.notice, .emailLooksWrong)
        XCTAssertEqual(model.step, .email)
    }

    /// Flip point: drop the length check in `verifyCode` and `verified` records the call — one
    /// wasted round trip per keystroke-in-progress, each one counting against GoTrue's own verify
    /// rate limit.
    func testAShortCodeIsRefusedWithoutCallingTheServer() async {
        let spy = CallSpy()
        let model = makeModel(clock: TestClock(), spy: spy)
        model.emailInput = "nedim@example.com"
        await model.sendCode()

        model.codeInput = "1234"
        await model.verifyCode()

        XCTAssertTrue(spy.verified.isEmpty, "four digits cannot be a six-digit code")
        XCTAssertEqual(model.notice, .codeIsSixDigits(typed: 4))
        XCTAssertTrue(model.notice?.text.contains("you've typed 4") == true)
    }

    /// The two shapes a code arrives in when it isn't typed. Flip point: return `raw` unchanged
    /// and both of these keep characters GoTrue rejects.
    func testPastedCodeTextIsReducedToItsSixDigits() {
        XCTAssertEqual(EmailCodeSignIn.digits(from: "Your code is 483920"), "483920")
        XCTAssertEqual(EmailCodeSignIn.digits(from: "48 39 20"), "483920")
        XCTAssertEqual(EmailCodeSignIn.digits(from: "4839201"), "483920", "six digits, then stop")
        XCTAssertEqual(EmailCodeSignIn.digits(from: "abc"), "")
    }

    /// A mistyped address is the most likely reason no code turns up, so the way back must not
    /// cost the user the address they already typed. Flip point: clear `emailInput` in
    /// `editEmail` and the assertion on it fails.
    func testUseADifferentEmailReturnsToStepOneWithTheAddressStillThere() async {
        let model = makeModel(clock: TestClock(), spy: CallSpy())
        model.emailInput = "  Nedim@Example.COM "
        await model.sendCode()
        XCTAssertEqual(model.step, .code)
        XCTAssertEqual(model.sentTo, "nedim@example.com",
                       "the address is normalised before it is sent, and shown back normalised")

        model.editEmail()

        XCTAssertEqual(model.step, .email)
        XCTAssertEqual(model.emailInput, "nedim@example.com")
        XCTAssertNil(model.notice)
    }

    /// GoTrue cannot tell a wrong code from an expired one (see `SupabaseError
    /// .invalidOrExpiredCode`), so the copy must name both and claim neither. What it must never
    /// be is either of the two things the old mapping produced: `.forbidden`'s "You don't have
    /// access to that", which reads as an account problem, or `.server`'s generic line.
    func testARejectedCodeIsNamedHonestlyAndNotAsAnAccessProblem() async {
        let spy = CallSpy()
        spy.verifyError = SupabaseError.invalidOrExpiredCode
        let model = makeModel(clock: TestClock(), spy: spy)
        model.emailInput = "nedim@example.com"
        await model.sendCode()

        model.codeInput = "483920"
        await model.verifyCode()

        XCTAssertEqual(model.notice, .codeRejected)
        let text = model.notice?.text ?? ""
        XCTAssertNotEqual(text, SupabaseError.forbidden.friendlyMessage,
                          "four wrong digits are not an access problem")
        XCTAssertNotEqual(text, SupabaseError.server(status: 403, message: "").friendlyMessage,
                          "the generic failure copy hides the one thing the user can act on")
        XCTAssertTrue(text.contains("mistyped"), "the copy must offer the likelier of the two causes")
        XCTAssertTrue(text.contains("send a new one"), "and the remedy that fixes either one")
        XCTAssertEqual(model.step, .code, "the user stays where the retry is")
    }

    /// A regression guard for a bug this task's live sign-in test found: `GoTrueTokenResponse`
    /// was decoded with `SupabaseJSON.decoder`, whose `.convertFromSnakeCase` rewrites the
    /// incoming `access_token` to `accessToken` before it can match the type's own explicit
    /// `case accessToken = "access_token"`. Every token exchange —`verifyEmailOTP`,
    /// `signInWithApple`, and `refresh`, which is what a returning user's launch depends on —
    /// threw `keyNotFound("access_token")` on a perfectly good 200. Nothing caught it because
    /// nothing in the app had ever called them.
    ///
    /// Flip point: decode this with the shared decoder instead and it throws.
    func testAGoTrueTokenResponseDecodesWithTheDecoderTheAuthClientActuallyUses() throws {
        // Field-for-field the shape a real local GoTrue returns from /verify.
        let body = Data("""
        {"access_token":"header.payload.signature","token_type":"bearer","expires_in":3600,
         "expires_at":1786887038,"refresh_token":"3o2xxbtwo3ry",
         "user":{"id":"21eeca83-4ba3-402f-9b27-ae1b083cbd5a","email":"someone@example.com"}}
        """.utf8)

        let response = try SupabaseJSON.goTrueDecoder.decode(GoTrueTokenResponse.self, from: body)

        XCTAssertEqual(response.accessToken, "header.payload.signature")
        XCTAssertEqual(response.refreshToken, "3o2xxbtwo3ry")
        XCTAssertEqual(response.user.id, UUID(uuidString: "21eeca83-4ba3-402f-9b27-ae1b083cbd5a"))
        XCTAssertEqual(response.makeSession(now: Date(timeIntervalSince1970: 0)).expiresAt,
                       Date(timeIntervalSince1970: 3600))

        XCTAssertThrowsError(try SupabaseJSON.decoder.decode(GoTrueTokenResponse.self, from: body),
                             "the shared decoder's key strategy is exactly what broke this — if " +
                             "this ever stops throwing, the two decoders have converged and the " +
                             "split above can go")
    }

    // MARK: - Against the real GoTrue on :54321, with the code read out of Mailpit

    /// The whole thing, unmocked: ask Supabase for a code, read the code out of the email
    /// Supabase actually sent, exchange it for a session, and land on the profile row the
    /// `on_auth_user_created` trigger inserted.
    ///
    /// `DemoWorld` is switched **on** first, deliberately. That is the state a user reaches by
    /// tapping "Explore in demo mode" and then signing out, and while it holds, every repository
    /// method in the app short-circuits to local fixtures and nothing reaches Supabase at all.
    /// The two assertions that pin it: `isActive` is false afterwards, and the profile is the
    /// server's (whose `display_name` the trigger seeds from the email's local part) and not
    /// `DemoWorld`'s Alice.
    func testSignInEndToEndWithTheCodeSupabaseActuallyEmailed() async throws {
        let config = try await requireLocalStack()
        let address = Self.uniqueAddress()
        let auth = Self.isolatedAuth(config: config)
        let session = SessionController(container: AppContainer(config: config, auth: auth))
        await DemoWorld.shared.activate(surname: "Alice")
        defer { Task { await DemoWorld.shared.deactivate() } }

        try await session.sendSignInCode(to: address)
        let code = try await Mailpit.latestCode(sentTo: address)
        XCTAssertEqual(code.count, 6, "Supabase emailed '\(code)', which is not a six-digit code — " +
                       "check supabase/templates/*.html still render {{ .Token }}")

        try await session.signIn(email: address, code: code)

        let hasSession = await auth.hasSession
        XCTAssertTrue(hasSession, "verifying the emailed code must leave a session behind")
        let demoActive = await DemoWorld.shared.isActive
        XCTAssertFalse(demoActive,
                       "a real session and an active DemoWorld must never coexist: every " +
                       "repository method checks isActive first, so while it is true the app " +
                       "never talks to Supabase and two phones stay two isolated local worlds")

        guard case let .onboarding(profile) = session.phase else {
            return XCTFail("a brand-new user has no legal-age confirmation yet, so the phase must " +
                           "be .onboarding; got \(session.phase)")
        }
        let uid = await auth.currentUserID
        XCTAssertEqual(profile.id, uid, "the profile must be the signed-in user's own row")
        XCTAssertEqual(profile.displayName, String(address.split(separator: "@")[0]),
                       "on_auth_user_created seeds display_name from the email's local part, so " +
                       "this value can only have come from the real database — DemoWorld would " +
                       "have answered 'Alice'")
        await auth.signOut()
    }

    /// Cold launch. A second `SupabaseAuth` reading the same Keychain is exactly what a relaunch
    /// does, and `bootstrap()` is what the app's root `.task` calls.
    ///
    /// Flip point for the headline claim: delete `DemoWorld.shared.deactivate()` from
    /// `SessionController.adoptRealSession()` and this fails twice over — `isActive` stays true,
    /// and the restored profile becomes Alice's rather than the signed-in user's.
    func testColdLaunchRestoresTheSessionAndTurnsDemoWorldOff() async throws {
        let config = try await requireLocalStack()
        let service = Self.uniqueKeychainService()
        let address = Self.uniqueAddress()

        let firstLaunch = SessionController(container: AppContainer(
            config: config, auth: Self.isolatedAuth(config: config, service: service)))
        try await firstLaunch.sendSignInCode(to: address)
        try await firstLaunch.signIn(email: address, code: try await Mailpit.latestCode(sentTo: address))
        guard case .onboarding = firstLaunch.phase else {
            return XCTFail("sanity: the first launch must have signed in; got \(firstLaunch.phase)")
        }

        let restoredAuth = Self.isolatedAuth(config: config, service: service)
        let coldLaunch = SessionController(container: AppContainer(config: config, auth: restoredAuth))
        XCTAssertEqual(coldLaunch.phase, .loading, "sanity: nothing has resolved the phase yet")
        await DemoWorld.shared.activate(surname: "Alice")
        defer { Task { await DemoWorld.shared.deactivate() } }

        await coldLaunch.bootstrap()

        let demoActive = await DemoWorld.shared.isActive
        XCTAssertFalse(demoActive,
                       "a launch that restores a session must leave DemoWorld off — otherwise the " +
                       "app boots into local fixtures with a perfectly good session in the Keychain")
        guard case let .onboarding(profile) = coldLaunch.phase else {
            return XCTFail("the restored session must resolve to a phase from the server; got \(coldLaunch.phase)")
        }
        let uid = await restoredAuth.currentUserID
        XCTAssertEqual(profile.id, uid)
        XCTAssertEqual(profile.displayName, String(address.split(separator: "@")[0]),
                       "the profile must come from the database, not from DemoWorld's Alice")
        await restoredAuth.signOut()
    }

    /// An empty Keychain must not produce a signed-in launch. Guards the other direction of the
    /// same invariant: `bootstrap()` used to reach `.ready` off a `UserDefaults` surname with no
    /// session at all.
    func testALaunchWithNoStoredSessionEndsSignedOutWithDemoWorldOff() async throws {
        let config = try await requireLocalStack()
        let session = SessionController(container: AppContainer(
            config: config, auth: Self.isolatedAuth(config: config)))
        await DemoWorld.shared.activate(surname: "Alice")

        await session.bootstrap()

        XCTAssertEqual(session.phase, .signedOut)
        let demoActive = await DemoWorld.shared.isActive
        XCTAssertFalse(demoActive,
                       "a signed-out launch must not inherit a demo world from whatever ran before it")
    }

    /// The real server's answer to a wrong code, and what the user is told about it. The wrong
    /// code is derived from the right one, so it cannot accidentally be correct.
    func testLiveGoTrueRejectsAWrongCodeAsInvalidOrExpiredNotAsForbidden() async throws {
        let config = try await requireLocalStack()
        let address = Self.uniqueAddress()
        let auth = Self.isolatedAuth(config: config)
        let session = SessionController(container: AppContainer(config: config, auth: auth))

        try await session.sendSignInCode(to: address)
        let real = try await Mailpit.latestCode(sentTo: address)
        let wrong = Self.oneDigitOff(real)
        XCTAssertNotEqual(wrong, real, "sanity: the wrong code must actually differ")

        do {
            try await session.signIn(email: address, code: wrong)
            XCTFail("a code Supabase never issued must not sign anyone in")
        } catch let error as SupabaseError {
            // GoTrue answers this with HTTP 403. Read through `SupabaseError.from`, 403 means
            // `.forbidden` — "You don't have access to that" — which is why `fromAuth` exists.
            XCTAssertEqual(error, .invalidOrExpiredCode,
                           "the live server's rejection must survive the mapping as a code problem")
            XCTAssertEqual(EmailCodeSignIn.notice(for: error), .codeRejected)
            XCTAssertNotEqual(error.friendlyMessage, SupabaseError.forbidden.friendlyMessage)
        }
        let hasSession = await auth.hasSession
        XCTAssertFalse(hasSession, "a rejected code must leave no session behind")
    }

    /// The real 429, which is the failure a friend testing this app is most likely to hit: hosted
    /// Supabase's built-in sender allows one code per address per minute.
    ///
    /// Deterministic because `supabase/config.toml` pins `[auth.email] max_frequency = "60s"` —
    /// the CLI's own default is 1s, which two HTTP round trips can outrun.
    func testLiveGoTrueThrottlesASecondSendAndTheHintCarriesTheWait() async throws {
        let config = try await requireLocalStack()
        let address = Self.uniqueAddress()
        let session = SessionController(container: AppContainer(
            config: config, auth: Self.isolatedAuth(config: config)))

        try await session.sendSignInCode(to: address)
        do {
            try await session.sendSignInCode(to: address)
            XCTFail("a second send inside max_frequency must be refused")
        } catch let error as SupabaseError {
            guard case let .rateLimited(hint) = error else {
                return XCTFail("a 429 from GoTrue must map to .rateLimited, got \(error)")
            }
            XCTAssertNotNil(hint, "GoTrue's own sentence is the only place the remaining wait exists")
            XCTAssertTrue(hint?.contains("seconds") == true,
                          "expected a wait sentence, got \(String(describing: hint))")
            XCTAssertNotEqual(error.friendlyMessage, "Something went wrong. Please try again.",
                              "the generic copy is exactly what this mapping exists to prevent")
            XCTAssertTrue(EmailCodeSignIn.notice(for: error).text.contains(hint ?? "\u{0}"),
                          "the screen must repeat the server's wait sentence, not paraphrase it")
        }
    }

    // MARK: - Fixtures

    private func makeModel(clock: TestClock, spy: CallSpy) -> EmailCodeSignIn {
        EmailCodeSignIn(
            send: { address in try spy.recordSend(address) },
            verify: { address, code in try spy.recordVerify(address, code) },
            now: { clock.now }
        )
    }

    /// A movable clock. `EmailCodeSignIn` reads the time through this, which is what lets the
    /// cooldown be asserted rather than waited out.
    @MainActor
    private final class TestClock {
        var now = Date(timeIntervalSince1970: 1_770_000_000)
    }

    /// Records what the model actually asked the network to do, and can be told to fail.
    @MainActor
    private final class CallSpy {
        var sentTo: [String] = []
        var verified: [(String, String)] = []
        var sendError: Error?
        var verifyError: Error?

        func recordSend(_ address: String) throws {
            sentTo.append(address)
            if let sendError { throw sendError }
        }

        func recordVerify(_ address: String, _ code: String) throws {
            verified.append((address, code))
            if let verifyError { throw verifyError }
        }
    }

    /// Every live test gets its own Keychain service. The app and this test bundle share a bundle
    /// id and therefore a Keychain, so a real session written under the app's own service name
    /// would still be there when the UI tests launch — and `OnboardingUITests` expects the
    /// welcome screen, not a signed-in app.
    private static func isolatedAuth(config: AppConfig, service: String? = nil) -> SupabaseAuth {
        SupabaseAuth(config: config, keychain: KeychainStore(service: service ?? uniqueKeychainService()))
    }

    private static func uniqueKeychainService() -> String {
        "app.cheekypint.tests.\(UUID().uuidString)"
    }

    private static func uniqueAddress() -> String {
        "cheekypint-test-\(UUID().uuidString.prefix(8).lowercased())@example.com"
    }

    /// A code guaranteed to differ from `code` in its first digit.
    private static func oneDigitOff(_ code: String) -> String {
        guard let first = code.first, let value = Int(String(first)) else { return "000000" }
        return String((value + 1) % 10) + String(code.dropFirst())
    }

    /// Skips — loudly — rather than passing quietly when the stack these cases are about isn't
    /// there. A silent pass would be indistinguishable from coverage.
    private func requireLocalStack() async throws -> AppConfig {
        let config = AppConfig.current
        guard let host = config.supabaseURL.host, host == "127.0.0.1" || host == "localhost" else {
            throw XCTSkip("Development.xcconfig points at \(config.supabaseURL), not the local " +
                          "stack — these cases sign real users in and must never run against a " +
                          "hosted project")
        }
        guard await isUp(config.authURL.appendingPathComponent("health")) else {
            throw XCTSkip("GoTrue is not answering on \(config.authURL) — run `supabase start`")
        }
        guard await isUp(Mailpit.messages) else {
            throw XCTSkip("Mailpit is not answering on \(Mailpit.messages) — run `supabase start`")
        }
        return config
    }

    private func isUp(_ url: URL) async -> Bool {
        guard let (_, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }
}

/// The mail catcher `supabase start` runs on :54324. Reading the code out of here is the only way
/// to get it: GoTrue stores `confirmation_token` as a hash of the code, so the database cannot
/// give it back, and the email is the only place the plaintext ever exists.
private enum Mailpit {
    static let base = URL(string: "http://127.0.0.1:54324")!
    static var messages: URL { base.appendingPathComponent("api/v1/messages") }

    /// The six-digit code from the newest message addressed to `email`.
    ///
    /// No polling and no waiting: GoTrue's local mailer hands the message to SMTP inside the
    /// `/otp` request, so by the time that call has returned 200 the message is already here.
    static func latestCode(sentTo email: String) async throws -> String {
        var components = URLComponents(url: base.appendingPathComponent("api/v1/search"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "query", value: "to:\(email)")]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        let payload = try JSONDecoder().decode(SearchResult.self, from: data)
        guard let newest = payload.messages.sorted(by: { $0.Created > $1.Created }).first else {
            throw MailpitError.noMessage(email)
        }
        let (body, _) = try await URLSession.shared.data(
            from: base.appendingPathComponent("api/v1/message/\(newest.ID)"))
        let message = try JSONDecoder().decode(Message.self, from: body)
        let text = message.Text ?? message.HTML ?? ""
        guard let range = text.range(of: "[0-9]{6}", options: .regularExpression) else {
            throw MailpitError.noCode(text)
        }
        return String(text[range])
    }

    private struct SearchResult: Decodable { let messages: [Summary] }
    private struct Summary: Decodable { let ID: String; let Created: String }
    private struct Message: Decodable { let Text: String?; let HTML: String? }

    enum MailpitError: Error, CustomStringConvertible {
        case noMessage(String)
        case noCode(String)

        var description: String {
            switch self {
            case let .noMessage(email):
                return "Mailpit has no message for \(email) — GoTrue accepted the request but sent nothing"
            case let .noCode(body):
                return "no six-digit code in the email body. Check supabase/templates/*.html " +
                       "still render {{ .Token }}. Body was: \(body.prefix(300))"
            }
        }
    }
}
