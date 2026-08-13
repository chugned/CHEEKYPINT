import XCTest
@testable import CheekyPint

/// `AccessibilityAnnouncer`'s dedup behaviour: both the pure decision (`shouldAnnounce`) and the
/// mutating `announce(_:)` wrapper, spied on via its injected `post` closure rather than the real
/// `UIAccessibility.post` — matching this codebase's usual seam style for anything that would
/// otherwise touch a system API from a test.
final class AccessibilityAnnouncerTests: XCTestCase {

    // MARK: - shouldAnnounce (pure)

    /// The headline case this type exists for: a genuinely new message, from nothing previously
    /// announced, must announce.
    func testANewMessageWithNothingPreviouslyAnnouncedShouldAnnounce() {
        XCTAssertTrue(AccessibilityAnnouncer.shouldAnnounce("You're offline.", lastAnnounced: nil))
    }

    /// `nil` — the message clearing, e.g. a retry resetting `errorMessage = nil` before the next
    /// attempt resolves — must never itself be announced.
    func testNilMessageNeverAnnounces() {
        XCTAssertFalse(AccessibilityAnnouncer.shouldAnnounce(nil, lastAnnounced: nil))
        XCTAssertFalse(AccessibilityAnnouncer.shouldAnnounce(nil, lastAnnounced: "You're offline."))
    }

    /// Whitespace-empty text is nothing to speak, matching every other "empty means nothing to
    /// show" rule in this codebase.
    func testEmptyMessageNeverAnnounces() {
        XCTAssertFalse(AccessibilityAnnouncer.shouldAnnounce("", lastAnnounced: nil))
    }

    /// The over-announcing case the audit specifically flagged: re-entering the *same* error text
    /// twice in a row (e.g. two Send attempts that both hit the identical offline failure) must
    /// not announce the second time.
    func testTheSameMessageAsLastAnnouncedDoesNotReAnnounce() {
        XCTAssertFalse(AccessibilityAnnouncer.shouldAnnounce("You're offline.", lastAnnounced: "You're offline."))
    }

    /// The flip side: once the message actually changes to different text, it must announce again
    /// — this is "don't repeat the identical sentence", not "announce once ever per screen".
    func testADifferentMessageThanLastAnnouncedDoesAnnounce() {
        XCTAssertTrue(AccessibilityAnnouncer.shouldAnnounce(
            "You've used all 5 exports allowed today. You can try again tomorrow.",
            lastAnnounced: "You're offline."))
    }

    // MARK: - announce(_:) (the mutating wrapper, spied via `post`)

    @MainActor
    func testAnnounceCallsPostExactlyOnceForOneNewMessage() {
        var posted: [String] = []
        var announcer = AccessibilityAnnouncer(post: { posted.append($0) })
        announcer.announce("You're offline.")
        XCTAssertEqual(posted, ["You're offline."])
    }

    @MainActor
    func testAnnounceClearingToNilCallsPostZeroTimes() {
        var posted: [String] = []
        var announcer = AccessibilityAnnouncer(post: { posted.append($0) })
        announcer.announce("You're offline.")
        announcer.announce(nil)
        XCTAssertEqual(posted, ["You're offline."], "nil must never itself be posted")
    }

    /// The exact scenario the audit's "be careful not to over-announce" warning is about: Send
    /// fails offline, the screen clears the error to retry, and the retry hits the *identical*
    /// failure again. `post` must fire once total, not twice — proving the intervening `nil`
    /// doesn't erase the memory of what was last actually spoken.
    @MainActor
    func testRetryingIntoTheIdenticalErrorAcrossAnInterveningNilPostsOnlyOnce() {
        var posted: [String] = []
        var announcer = AccessibilityAnnouncer(post: { posted.append($0) })
        announcer.announce("You're offline.")
        announcer.announce(nil)
        announcer.announce("You're offline.")
        XCTAssertEqual(posted, ["You're offline."],
                       "a repeat of the same text after clearing to nil must not re-announce")
        XCTAssertEqual(announcer.lastAnnounced, "You're offline.")
    }

    /// A genuinely different second message (not a repeat) must still post, so this isn't
    /// "announce once ever" masquerading as dedup.
    @MainActor
    func testASecondDifferentMessagePostsAgain() {
        var posted: [String] = []
        var announcer = AccessibilityAnnouncer(post: { posted.append($0) })
        announcer.announce("You're offline.")
        announcer.announce(nil)
        announcer.announce("Couldn't post that. Please try again.")
        XCTAssertEqual(posted, ["You're offline.", "Couldn't post that. Please try again."])
    }
}
