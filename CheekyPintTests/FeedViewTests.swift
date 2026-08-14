import XCTest
@testable import CheekyPint

/// `FeedView`'s pure error-icon mapping (`docs/STATE_AUDIT.md`'s Low finding: the full-screen
/// error `StatusView` used to hard-code `wifi.slash` for every `SupabaseError`, so a rate-limited
/// user — whose copy correctly says "That's a lot at once — give it a moment." — saw the universal
/// "you have no internet" glyph anyway). `FeedView.errorIcon(for:)` is `static` specifically so it
/// can be called directly here without standing up a view, a `FeedViewModel`, or a container.
final class FeedViewTests: XCTestCase {
    /// The concrete input that flips this test: `.rateLimited` must not resolve to the same icon
    /// as `.offline`. Before this fix there was no `errorIcon(for:)` at all — the icon was a
    /// literal `"wifi.slash"` inlined at the `StatusView` call site regardless of `error`'s case —
    /// so collapsing this function back to `"wifi.slash"` unconditionally (verified by hand) turns
    /// this red again, which is exactly the bug the audit found.
    func testRateLimitedIconDiffersFromOfflineIcon() {
        XCTAssertNotEqual(FeedView.errorIcon(for: .rateLimited(hint: nil)),
                           FeedView.errorIcon(for: .offline),
                           "a client-side throttle must not show the same icon as a genuine outage")
    }

    func testOfflineUsesTheConnectivityIcon() {
        XCTAssertEqual(FeedView.errorIcon(for: .offline), "wifi.slash")
    }

    /// `docs/STATE_AUDIT.md`'s own suggested fix, verbatim: "e.g. `hourglass` for rate limits".
    func testRateLimitedUsesAnHourglassNotAConnectivityIcon() {
        XCTAssertEqual(FeedView.errorIcon(for: .rateLimited(hint: nil)), "hourglass")
    }

    /// A generic server failure is neither "you're offline" nor "slow down" — it should read as
    /// neither of those specific icons.
    func testServerErrorDoesNotClaimAConnectivityOrRateLimitIcon() {
        let icon = FeedView.errorIcon(for: .server(status: 500, message: "boom"))
        XCTAssertNotEqual(icon, "wifi.slash")
        XCTAssertNotEqual(icon, "hourglass")
    }
}
