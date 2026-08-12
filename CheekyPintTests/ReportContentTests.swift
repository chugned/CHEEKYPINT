import XCTest
import CheekyPintCore
@testable import CheekyPint

/// `ReportContentView`'s two testable, pure seams: `defaultCategory(for:)` (what the `Picker`
/// starts on) and `report(target:category:details:reportPost:reportComment:)` (routing). Neither
/// touches `@State` or `container`, matching `FeedViewModel`'s "inject the repository call as a
/// closure" seam style so a test can observe exactly which call fired.
final class ReportContentTests: XCTestCase {

    // MARK: - defaultCategory(for:)

    /// A post carrying a photo must default to the photo-specific category. Flip input: `hasPhoto:
    /// false` on the same case (below) must produce a different result, or this default isn't
    /// actually reading `hasPhoto` at all.
    func testDefaultCategoryForAPostWithAPhotoIsInappropriatePostImage() {
        let target = ReportTarget.post(id: UUID(), hasPhoto: true)
        XCTAssertEqual(ReportContentView.defaultCategory(for: target), .inappropriatePostImage,
                       "a post with a photo must default to the photo category")
    }

    /// The flip side of the above: the same `.post` case with `hasPhoto: false` must default to
    /// the generic text category, not the photo one — proving the default genuinely branches on
    /// `hasPhoto` rather than being a constant per-case default.
    func testDefaultCategoryForATextOnlyPostIsInappropriateText() {
        let target = ReportTarget.post(id: UUID(), hasPhoto: false)
        XCTAssertEqual(ReportContentView.defaultCategory(for: target), .inappropriateText,
                       "a text-only post (no photo) must default to the text category, not the photo one")
    }

    /// A comment carries no photo of its own, so it must always default to the text category.
    func testDefaultCategoryForACommentIsInappropriateText() {
        let target = ReportTarget.comment(id: UUID())
        XCTAssertEqual(ReportContentView.defaultCategory(for: target), .inappropriateText,
                       "a comment must default to the text category — it has no photo field to check")
    }

    /// A user report must keep the value the standalone `ReportUserView` started its `Picker` on,
    /// so folding that screen into this one changed no visible default.
    func testDefaultCategoryForAUserIsInappropriateText() {
        let target = ReportTarget.user(id: UUID())
        XCTAssertEqual(ReportContentView.defaultCategory(for: target), .inappropriateText,
                       "a user report must default to the text category, as the standalone screen did")
    }

    // MARK: - report(target:...) routing

    /// The Step 6 gate: a `.post` target must call `reportPost` and must NEVER call
    /// `reportComment`/`reportUser`. A regression that routes several targets to `reportPost` would
    /// still pass this third (by accident) but fails the mirror-image tests below — the trio
    /// together is what proves each target reaches its own call, not just "some call happened".
    func testPostTargetRoutesToReportPostAndNothingElse() async throws {
        let postID = UUID()
        var reportPostCalled: (id: UUID, category: ReportCategory, details: String?)?
        var reportCommentCallCount = 0
        var reportUserCallCount = 0

        try await ReportContentView.report(
            target: .post(id: postID, hasPhoto: false), category: .harassment, details: "rude comment",
            reportPost: { id, category, details in reportPostCalled = (id, category, details) },
            reportComment: { _, _, _ in reportCommentCallCount += 1 },
            reportUser: { _, _, _ in reportUserCallCount += 1 }
        )

        XCTAssertEqual(reportPostCalled?.id, postID, "reportPost must receive the post's own id")
        XCTAssertEqual(reportPostCalled?.category, .harassment, "reportPost must receive the chosen category")
        XCTAssertEqual(reportPostCalled?.details, "rude comment", "reportPost must receive the typed details")
        XCTAssertEqual(reportCommentCallCount, 0, "a .post target must never call reportComment")
        XCTAssertEqual(reportUserCallCount, 0, "a .post target must never call reportUser")
    }

    /// The mirror image: a `.comment` target must call `reportComment` and nothing else. Combined
    /// with the two neighbouring tests, more than one repository call firing for any target (the
    /// exact defect Step 6 proves is caught) fails at least one of the trio.
    func testCommentTargetRoutesToReportCommentAndNothingElse() async throws {
        let commentID = UUID()
        var reportCommentCalled: (id: UUID, category: ReportCategory, details: String?)?
        var reportPostCallCount = 0
        var reportUserCallCount = 0

        try await ReportContentView.report(
            target: .comment(id: commentID), category: .other, details: nil,
            reportPost: { _, _, _ in reportPostCallCount += 1 },
            reportComment: { id, category, details in reportCommentCalled = (id, category, details) },
            reportUser: { _, _, _ in reportUserCallCount += 1 }
        )

        XCTAssertEqual(reportCommentCalled?.id, commentID, "reportComment must receive the comment's own id")
        XCTAssertEqual(reportCommentCalled?.category, .other, "reportComment must receive the chosen category")
        XCTAssertNil(reportCommentCalled?.details, "nil details (no text typed) must be passed through as nil")
        XCTAssertEqual(reportPostCallCount, 0, "a .comment target must never call reportPost")
        XCTAssertEqual(reportUserCallCount, 0, "a .comment target must never call reportUser")
    }

    /// The third leg, and the point of folding `ReportUserView` into this view: a `.user` target
    /// must reach `FriendsRepository.report` (the `report_user` RPC) and neither feed RPC. The two
    /// content targets write `reports.post_id`/`comment_id`; a user report must not, so misrouting
    /// here would attach a profile report to an unrelated post id.
    func testUserTargetRoutesToReportUserAndNothingElse() async throws {
        let userID = UUID()
        var reportUserCalled: (id: UUID, category: ReportCategory, details: String?)?
        var reportPostCallCount = 0
        var reportCommentCallCount = 0

        try await ReportContentView.report(
            target: .user(id: userID), category: .harassment, details: "abusive",
            reportPost: { _, _, _ in reportPostCallCount += 1 },
            reportComment: { _, _, _ in reportCommentCallCount += 1 },
            reportUser: { id, category, details in reportUserCalled = (id, category, details) }
        )

        XCTAssertEqual(reportUserCalled?.id, userID, "reportUser must receive the reported user's own id")
        XCTAssertEqual(reportUserCalled?.category, .harassment, "reportUser must receive the chosen category")
        XCTAssertEqual(reportUserCalled?.details, "abusive", "reportUser must receive the typed details")
        XCTAssertEqual(reportPostCallCount, 0, "a .user target must never call reportPost")
        XCTAssertEqual(reportCommentCallCount, 0, "a .user target must never call reportComment")
    }

    /// Empty details must become `nil`, not an empty string — this is exercised at the view's
    /// `send()` call site, not here, since `report(...)` itself is a dumb router that forwards
    /// whatever `details` it's given. Documented here so the convention isn't lost:
    /// `ReportContentView.send()` must perform this conversion before calling `report(...)`.
    func testReportForwardsDetailsExactlyAsGiven() async throws {
        let postID = UUID()
        var forwardedDetails: String??
        try await ReportContentView.report(
            target: .post(id: postID, hasPhoto: true), category: .inappropriatePostImage, details: "",
            reportPost: { _, _, details in forwardedDetails = details },
            reportComment: { _, _, _ in },
            reportUser: { _, _, _ in }
        )
        XCTAssertEqual(forwardedDetails, "", "report(...) forwards details verbatim; nil-conversion is send()'s job")
    }

    // MARK: - sanitizedDetails
    //
    // `reports.details` is read by a **human moderator** deciding whether reported text is abusive,
    // so a bidi override or a zero-width run in the details is a payload aimed at the person
    // adjudicating it. Unsanitised free text is not unique to this surface —
    // `pub_sessions.name` (SessionViews) and `pint_entries.private_note` (LogPintSheet) still go out
    // raw at the time of writing — but it is the one where the payload's target is the reader.
    //
    // Because all three targets now share one `send()`, these assertions cover the user-report path
    // too; before the merge that path forwarded `details` raw with no bound. The server halves add
    // `strip_ugc_control_chars` to `report_post`, `report_comment` (t43e) and `report_user` (t43f)
    // in supabase/tests/rls_rpc_suite.sql.

    /// The exact Trojan Source shapes `ProfileTextSanitizer` exists for, in the details field.
    func testSanitizedDetailsStripsBidiOverridesAndZeroWidthCharacters() throws {
        let payload = "ab\u{200B}us\u{202E}i\u{2060}ve"
        let clean = try XCTUnwrap(ReportContentView.sanitizedDetails(payload))
        XCTAssertEqual(clean, "abusive",
                       "a zero-width space, a right-to-left override and a word joiner must all be " +
                       "gone before a moderator reads this")
        XCTAssertFalse(clean.unicodeScalars.contains { $0.properties.generalCategory == .format },
                       "no format-category scalar may survive into the moderation queue")
    }

    /// Bounded to the server's own `left(btrim(strip_ugc_control_chars(p_details)), 1000)`, measured
    /// in the code points Postgres counts. 1000 is a literal: the constant exists only to mirror
    /// that SQL, which is now identical in all three report RPCs.
    func testSanitizedDetailsIsBoundedToTheServerLimitInCodePoints() throws {
        XCTAssertEqual(ReportContentView.detailsLimit, 1000,
                       "must mirror the report RPCs' left(…, 1000) and reports.details' own CHECK")

        let ascii = try XCTUnwrap(ReportContentView.sanitizedDetails(String(repeating: "z", count: 1500)))
        XCTAssertEqual(ascii.unicodeScalars.count, 1000)

        // 800 NFD characters is 1600 code points: a grapheme-based bound would pass it straight
        // through for the server to cut.
        let nfd = try XCTUnwrap(ReportContentView.sanitizedDetails(String(repeating: "a\u{0308}", count: 800)))
        XCTAssertEqual(nfd.unicodeScalars.count, 1000,
                       "the bound must be in the unit left(…, 1000) counts")
    }

    /// Send is disabled past the limit rather than letting the tail vanish silently — the same rule
    /// the two composers follow. Details are optional, so within-limit-and-empty must stay allowed.
    func testDetailsOverTheLimitBlocksSendButEmptyDetailsDoNot() {
        XCTAssertTrue(ReportContentView.detailsWithinLimit(""), "details are optional")
        XCTAssertTrue(ReportContentView.detailsWithinLimit(String(repeating: "z", count: 1000)),
                      "exactly 1000 must still be sendable")
        XCTAssertFalse(ReportContentView.detailsWithinLimit(String(repeating: "z", count: 1001)),
                       "1001 characters must block Send, not lose the 1001st on send")
        XCTAssertFalse(ReportContentView.detailsWithinLimit(String(repeating: "a\u{0308}", count: 501)),
                       "1002 code points must block Send even though it is only 501 characters")
    }

    /// Whitespace-only details are nothing to tell a moderator: they must arrive as `nil`, keeping
    /// the column empty rather than storing a blank string.
    func testWhitespaceOnlyDetailsBecomeNil() {
        XCTAssertNil(ReportContentView.sanitizedDetails(""))
        XCTAssertNil(ReportContentView.sanitizedDetails("   \n\t "))
        XCTAssertNil(ReportContentView.sanitizedDetails("\u{200B}\u{202E}"),
                     "details consisting only of invisible characters are empty once stripped")
        XCTAssertEqual(ReportContentView.sanitizedDetails("  rude  "), "rude")
    }
}
