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
}
