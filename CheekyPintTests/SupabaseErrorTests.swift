import XCTest
@testable import CheekyPint

/// Code review's Minor finding on Task 5: `report_post`/`report_comment` already reject a
/// self-report server-side with SQLSTATE `22023` (`'Cannot report yourself'`), but
/// `SupabaseError.from` had no case for `22023`, so it fell through to `.server`, whose
/// `friendlyMessage` is always the generic "Something went wrong. Please try again." — losing the
/// server's own, already user-appropriate message. `22023` is reused across this schema for many
/// distinct hand-written validation messages (not just self-reports), so the fix passes the
/// message straight through rather than hard-coding copy for one specific message.
final class SupabaseErrorTests: XCTestCase {

    private func body(message: String, code: String) -> Data {
        Data("{\"message\":\"\(message)\",\"code\":\"\(code)\"}".utf8)
    }

    /// The concrete case the review flagged: a self-report must surface the server's own message,
    /// not the generic `.server` copy.
    func test22023MapsToValidationAndSurfacesTheServersOwnMessage() {
        let error = SupabaseError.from(status: 400, body: body(message: "Cannot report yourself", code: "22023"))
        XCTAssertEqual(error, .validation("Cannot report yourself"))
        XCTAssertEqual(error.friendlyMessage, "Cannot report yourself",
                       "a 22023 validation message must be shown verbatim, not replaced with " +
                       "the generic .server copy")
    }

    /// `22023` is not exclusive to self-reports — `create_post`, `add_comment`, and others reuse
    /// it for their own distinct messages. This proves the mapping is generic (any 22023 message
    /// passes through), not a special case hard-coded to "Cannot report yourself" specifically —
    /// the flip: a hard-coded implementation would fail this with a different message but pass
    /// the test above.
    func test22023PassesThroughAnyMessageNotJustTheSelfReportOne() {
        let error = SupabaseError.from(status: 400, body: body(
            message: "A post needs a photo or some words", code: "22023"))
        XCTAssertEqual(error.friendlyMessage, "A post needs a photo or some words")
    }

    /// The regression guard for the fix's own scope: an unmapped code must still fall through to
    /// `.server` with the generic copy, never the raw server message. Without this, a fix that
    /// (wrongly) made ALL unmapped codes pass their message through — not just 22023 — would leak
    /// unreviewed technical/internal strings to the user, and this test is what would catch it.
    func testAnUnmappedCodeStillFallsThroughToTheGenericServerMessage() {
        let error = SupabaseError.from(status: 500, body: body(
            message: "relation public.posts does not exist", code: "XXXXX"))
        XCTAssertEqual(error, .server(status: 500, message: "relation public.posts does not exist"))
        XCTAssertEqual(error.friendlyMessage, "Something went wrong. Please try again.",
                       "an unmapped code's raw message must never be shown to the user")
    }

    /// Codes mapped to other cases before 22023 was added must be unaffected — a defect that
    /// widened the 22023 match (e.g. a careless default case) could plausibly swallow these too.
    func testOtherKnownCodesAreUnaffectedByTheNewValidationCase() {
        XCTAssertEqual(SupabaseError.from(status: 400, body: body(message: "nope", code: "P0002")), .notFound)
        XCTAssertEqual(SupabaseError.from(status: 403, body: body(message: "nope", code: "42501")), .forbidden)
    }

    // MARK: - GoTrue's own error envelope
    //
    // Every body below is copied verbatim from a real local GoTrue v2.195.0 (`supabase start`,
    // `curl` against :54321). `EmailOTPAuthTests` re-derives the same two failures against the
    // running server, so if GoTrue changes its wire format these fixtures cannot silently rot
    // into fiction — the live cases fail first.

    private let goTrueRateLimit = Data(#"{"code":429,"error_code":"over_email_send_rate_limit","msg":"For security purposes, you can only request this after 47 seconds."}"#.utf8)
    private let goTrueOTPExpired = Data(#"{"code":403,"error_code":"otp_expired","msg":"Token has expired or is invalid"}"#.utf8)

    /// Why `fromAuth` had to exist at all. GoTrue's `code` is a *number*; PostgREST's is a string,
    /// so decoding a GoTrue body as `PostgRESTError` throws outright and the whole payload is
    /// lost. This asserts the broken behaviour deliberately: if someone later "simplifies" the
    /// auth client back onto `from(status:body:)`, this test is the record of what that costs.
    func testThePostgRESTMappingCannotReadAGoTrueBodyAtAll() {
        XCTAssertEqual(SupabaseError.from(status: 429, body: goTrueRateLimit).friendlyMessage,
                       "Something went wrong. Please try again.",
                       "a throttled send read through the PostgREST mapping is indistinguishable " +
                       "from any other server failure")
        XCTAssertEqual(SupabaseError.from(status: 403, body: goTrueOTPExpired), .forbidden,
                       "and a mistyped code becomes 'You don't have access to that'")
    }

    /// The remaining wait is only ever in the server's sentence — nothing on the client knows it —
    /// so the hint has to carry it through to the screen.
    func testGoTrueRateLimitKeepsTheServersOwnWaitSentence() {
        let error = SupabaseError.fromAuth(status: 429, body: goTrueRateLimit)
        XCTAssertEqual(error, .rateLimited(hint: "For security purposes, you can only request this after 47 seconds."))
        XCTAssertTrue(error.friendlyMessage.contains("47 seconds"))
    }

    /// Flip point: map 403 before `error_code` in `fromAuth` and this returns `.forbidden`.
    func testGoTrueOTPExpiredMapsToTheCodeCaseAndNotToForbidden() {
        let error = SupabaseError.fromAuth(status: 403, body: goTrueOTPExpired)
        XCTAssertEqual(error, .invalidOrExpiredCode)
        XCTAssertNotEqual(error.friendlyMessage, SupabaseError.forbidden.friendlyMessage)
    }

    /// Also the guard on which decoder reads these: swap `SupabaseJSON.goTrueDecoder` for the
    /// shared `SupabaseJSON.decoder` and its `.convertFromSnakeCase` rewrites `error_code` to
    /// `errorCode` before `GoTrueError`'s explicit key can match it, so `error_code` reads as nil
    /// and every GoTrue failure falls through to `.server`'s generic copy.
    func testGoTrueValidationFailureSurfacesTheServersOwnSentence() {
        let body = Data(#"{"code":400,"error_code":"validation_failed","msg":"Unable to validate email address: invalid format"}"#.utf8)
        XCTAssertEqual(SupabaseError.fromAuth(status: 400, body: body),
                       .validation("Unable to validate email address: invalid format"))
    }

    /// An auth failure with no shape we recognise must still not leak a raw server string.
    func testAnUnrecognisedAuthFailureStillGetsTheGenericCopy() {
        let body = Data(#"{"code":500,"error_code":"unexpected_failure","msg":"pq: connection reset"}"#.utf8)
        let error = SupabaseError.fromAuth(status: 500, body: body)
        XCTAssertEqual(error, .server(status: 500, message: "pq: connection reset"))
        XCTAssertEqual(error.friendlyMessage, "Something went wrong. Please try again.")
    }
}
