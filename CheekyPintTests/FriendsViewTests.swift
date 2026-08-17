import XCTest
@testable import CheekyPint

/// `FriendsView.respondFailureMessage(for:accepting:name:)` — the copy a failed accept or decline
/// puts on screen.
///
/// `FriendsViewModel.respond` used to be `try? await container.friends.respond(...)`, so a refused
/// accept left the row sitting in Requests with nothing to explain it: identical on screen to a tap
/// that missed the button. (It is why `FriendFlowUITests` has to gate the friendship on
/// `get_friends()`'s empty state rather than on any error surface.) It now captures the failure into
/// the same `error` property `load()` uses, and this function is what that property says.
///
/// `static` for the same reason `FeedView.errorIcon(for:)` and `DataExportView.errorMessage(for:)`
/// are: it can be called here without a view, a view model, a container or a simulator.
final class FriendsViewTests: XCTestCase {

    private let person = "Bram"

    // MARK: - .notFound, the failure this RPC actually produces

    /// `respond_to_friend_request` raises `P0002 'Request not found'`
    /// (`supabase/migrations/20260101000800_rpc_social.sql:141`) for any row that is no longer
    /// `pending` with the caller as addressee — withdrawn, already answered on another device, or
    /// the account is gone. `SupabaseError.from` maps `P0002` to `.notFound`, whose
    /// `friendlyMessage` is "That's not available." — true, and useless on this screen.
    ///
    /// The concrete input that flips this: collapse the function body to
    /// `error.friendlyMessage` (or drop the `.notFound` branch) and this string is exactly
    /// "That's not available.", which is what the assertion forbids.
    func testRequestNoLongerPendingDoesNotFallBackToTheGenericNotFoundCopy() {
        let message = FriendsView.respondFailureMessage(for: SupabaseError.notFound,
                                                        accepting: true, name: person)
        XCTAssertNotEqual(message, SupabaseError.notFound.friendlyMessage,
                          "a request that is no longer pending must not be reported with " +
                          "`.notFound`'s generic copy — \"That's not available.\" names nothing " +
                          "on this screen and suggests nothing to do")
        XCTAssertTrue(message.contains("withdrawn"),
                      "the copy must say why the request could have vanished. Got: '\(message)'")
        XCTAssertTrue(message.contains("refresh"),
                      "the copy must say what to do next. Got: '\(message)'")
    }

    // MARK: - Which action didn't happen

    /// On success the row leaves the Requests section, and that disappearance is the whole
    /// confirmation. A row that stays put has to be told apart from a missed tap, so the sentence
    /// names the action. Flip point: return one string for both, and these differ no longer.
    func testAcceptAndDeclineDoNotProduceTheSameSentence() {
        let accepted = FriendsView.respondFailureMessage(for: SupabaseError.notFound,
                                                         accepting: true, name: person)
        let declined = FriendsView.respondFailureMessage(for: SupabaseError.notFound,
                                                         accepting: false, name: person)
        XCTAssertNotEqual(accepted, declined,
                          "a failed accept and a failed decline must not read identically — the " +
                          "user has to know which one didn't happen")
        XCTAssertTrue(accepted.contains("accept"), "the accept copy must say 'accept'. Got: '\(accepted)'")
        XCTAssertTrue(declined.contains("decline"), "the decline copy must say 'decline'. Got: '\(declined)'")
    }

    /// Flip point: drop `name` from the interpolation and this fails — with two pending requests
    /// on screen, an unattributed failure doesn't say whose.
    func testTheSentenceNamesThePersonWhoseRequestFailed() {
        let message = FriendsView.respondFailureMessage(for: SupabaseError.offline,
                                                        accepting: true, name: "Ceri")
        XCTAssertTrue(message.contains("Ceri"),
                      "the copy must name whose request failed. Got: '\(message)'")
    }

    // MARK: - Everything else keeps copy that was already written for a user

    /// `.rateLimited`'s payload is the server's own sentence, which carries a number of seconds
    /// nothing on the client can compute. Flip point: replace the default branch with a fixed
    /// string and this hint disappears.
    func testRateLimitedKeepsTheServersOwnHint() {
        let hint = "Please slow down and try again in 41 seconds."
        let message = FriendsView.respondFailureMessage(for: SupabaseError.rateLimited(hint: hint),
                                                        accepting: true, name: person)
        XCTAssertTrue(message.contains(hint),
                      "the server's hint is the only thing that knows how long to wait; it must " +
                      "survive into the displayed copy. Got: '\(message)'")
    }

    /// `.offline` and `.notAuthenticated` already say what to do, so they are passed through rather
    /// than paraphrased. Flip point: swap the default branch for "Please try again." and both of
    /// these lose their own instruction.
    func testOfflineAndNotAuthenticatedKeepTheirOwnInstruction() {
        let offline = FriendsView.respondFailureMessage(for: SupabaseError.offline,
                                                        accepting: true, name: person)
        XCTAssertTrue(offline.contains(SupabaseError.offline.friendlyMessage),
                      "'\(offline)' dropped the offline copy, which is the only thing that tells " +
                      "the user this will retry itself")
        let signIn = FriendsView.respondFailureMessage(for: SupabaseError.notAuthenticated,
                                                       accepting: false, name: person)
        XCTAssertTrue(signIn.contains(SupabaseError.notAuthenticated.friendlyMessage),
                      "'\(signIn)' dropped the sign-in instruction")
    }

    /// Nothing may come back blank. `FriendsViewModel.respond` catches *every* error, not only
    /// `SupabaseError` — a `URLError`, a decoding failure or anything else still has to produce a
    /// sentence that names the action. Flip point: return `""` for the non-`SupabaseError` path and
    /// the screen shows an empty warning row.
    func testANonSupabaseErrorStillNamesTheActionAndThePerson() {
        let message = FriendsView.respondFailureMessage(for: URLError(.badServerResponse),
                                                        accepting: true, name: person)
        XCTAssertFalse(message.isEmpty, "an unrecognised error must not produce an empty warning row")
        XCTAssertTrue(message.contains("accept") && message.contains(person),
                      "even an unrecognised error must say what didn't happen and to whom. " +
                      "Got: '\(message)'")
    }

    // MARK: - The wiring, not just the copy

    /// The copy above is worth nothing if `respond` never reaches it, which is exactly what `try?`
    /// used to guarantee. This drives the real `FriendsViewModel` against a container with an empty
    /// per-test Keychain, so `SupabaseData.perform`'s `try await auth.validAccessToken()`
    /// (`SupabaseAuth.swift:27`) throws `.notAuthenticated` before a single byte leaves the process
    /// — hermetic, offline and instant, and still a genuine throw from the real repository.
    ///
    /// **The concrete input that flips it**: put `try?` back. `respond` then swallows the throw and
    /// falls through to `load()`, which fails the same way and sets `error = .notAuthenticated`
    /// ("Please sign in again.") — non-nil, so a bare `XCTAssertNotNil` would still pass. Only the
    /// action and the requester's name can tell the two apart, and neither can come from `load()`,
    /// which has never seen a `PendingRequestDTO`. Verified by hand; see the commit message.
    @MainActor
    func testAFailedRespondReachesTheErrorSurfaceInsteadOfBeingSwallowed() async {
        // `FriendsRepository.respond` returns without doing anything while demo mode is on, so a
        // world left active by another case in this bundle would make the RPC succeed vacuously.
        await DemoWorld.shared.deactivate()

        let config = AppConfig(environment: .development,
                               supabaseURL: URL(string: "https://unreachable.invalid")!,
                               supabaseAnonKey: "k", universalHost: "unreachable.invalid")
        let auth = SupabaseAuth(
            config: config,
            keychain: KeychainStore(service: "test.cheekypint.friends-respond.\(UUID().uuidString)"))
        let model = FriendsViewModel(container: AppContainer(config: config, auth: auth))
        let request = PendingRequestDTO(friendshipId: UUID(), userId: UUID(),
                                        displayName: "Bram", avatarPath: nil, requestedAt: Date())

        await model.respond(request, accept: true)

        let message = model.error?.friendlyMessage ?? "<nothing on the error surface>"
        XCTAssertTrue(message.contains("accept"),
                      "a failed accept left nothing that names the accept on the screen's error " +
                      "surface, so it is indistinguishable from a tap that missed the button. " +
                      "Got: '\(message)'")
        XCTAssertTrue(message.contains("Bram"),
                      "the message on the error surface is not about this request — `load()`'s own " +
                      "failure has replaced it, which is what happens when `respond` swallows its " +
                      "error and re-loads. Got: '\(message)'")
    }
}
