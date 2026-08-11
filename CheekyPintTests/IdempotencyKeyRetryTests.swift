import XCTest
@testable import CheekyPint

/// Covers the retry-safety rule behind `LogPintSheet.log(_:)` (fix round 1, Important #2): a
/// failed save must leave a pending key in place so a retry tap on the *same* beer reuses it —
/// otherwise the idempotent RPC never recognises the retry and a flaky network creates a second
/// pint. `LogPintSheet.log(_:)` itself can't be unit tested directly: it's a private method on a
/// SwiftUI `View` that needs `@Environment(\.container)` and `@Environment(\.dismiss)`, neither of
/// which is obtainable outside a real view hierarchy without pulling in a view-inspection
/// dependency (which the app deliberately has none of). `resolveIdempotencyKey` is the pure
/// decision rule extracted out of `log(_:)` for exactly this reason, so these tests exercise it
/// directly instead of asserting nothing.
final class IdempotencyKeyRetryTests: XCTestCase {

    func testFirstTapOnABeerGeneratesAFreshKey() {
        let result = resolveIdempotencyKey(for: "puntigamer", pending: nil) { "generated-key" }
        XCTAssertEqual(result.key, "generated-key")
        XCTAssertEqual(result.pending.beerID, "puntigamer")
        XCTAssertEqual(result.pending.key, "generated-key")
    }

    /// The regression this covers: after a failed save, retrying the *same* beer must reuse the
    /// exact key from the first attempt (and must not mint a new one), so the server's dedupe RPC
    /// treats it as the same submission.
    func testRetryOfTheSameBeerReusesThePendingKeyWithoutGeneratingANewOne() {
        var generateCallCount = 0
        let generate = { () -> String in
            generateCallCount += 1
            return "key-\(generateCallCount)"
        }

        // First attempt fails; the sheet keeps `pending` as returned here.
        let firstAttempt = resolveIdempotencyKey(for: "puntigamer", pending: nil, generate: generate)
        XCTAssertEqual(firstAttempt.key, "key-1")

        // Retry tap on the same beer.
        let retry = resolveIdempotencyKey(
            for: "puntigamer",
            pending: firstAttempt.pending,
            generate: generate
        )

        XCTAssertEqual(retry.key, firstAttempt.key, "a retry of the same beer must reuse its key")
        XCTAssertEqual(generateCallCount, 1, "the retry must not mint a fresh key")
    }

    /// A tap on a *different* beer while a previous beer's failed attempt is still pending must
    /// not reuse that unrelated key.
    func testTappingADifferentBeerWhilePendingGeneratesItsOwnFreshKey() {
        var generateCallCount = 0
        let generate = { () -> String in
            generateCallCount += 1
            return "key-\(generateCallCount)"
        }

        let firstAttempt = resolveIdempotencyKey(for: "puntigamer", pending: nil, generate: generate)

        let secondBeer = resolveIdempotencyKey(
            for: "stiegl",
            pending: firstAttempt.pending,
            generate: generate
        )

        XCTAssertNotEqual(secondBeer.key, firstAttempt.key)
        XCTAssertEqual(secondBeer.pending.beerID, "stiegl")
        XCTAssertEqual(generateCallCount, 2)
    }

    /// Mirrors `LogPintSheet.log(_:)` clearing `pendingKey` on success: once cleared, the next tap
    /// on that same beer (a fresh log, not a retry) must get a brand-new key.
    func testAfterSuccessClearingThePendingKeyMeansTheNextTapGetsAFreshOne() {
        var generateCallCount = 0
        let generate = { () -> String in
            generateCallCount += 1
            return "key-\(generateCallCount)"
        }

        let firstAttempt = resolveIdempotencyKey(for: "puntigamer", pending: nil, generate: generate)
        // Simulate `pendingKey = nil` after `createPint` succeeds.
        let pendingAfterSuccess: (beerID: String, key: String)? = nil

        let nextLog = resolveIdempotencyKey(for: "puntigamer", pending: pendingAfterSuccess, generate: generate)

        XCTAssertNotEqual(nextLog.key, firstAttempt.key)
        XCTAssertEqual(generateCallCount, 2)
    }
}
