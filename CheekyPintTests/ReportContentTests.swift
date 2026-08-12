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

    // MARK: - report(target:...) routing

    /// The Step 6 gate: a `.post` target must call `reportPost` and must NEVER call
    /// `reportComment`. A regression that routes both targets to `reportPost` would still pass
    /// this half (by accident) but fails the mirror-image comment test below — the pair together
    /// is what proves each target reaches its own call, not just "some call happened".
    func testPostTargetRoutesToReportPostAndNeverReportComment() async throws {
        let postID = UUID()
        var reportPostCalled: (id: UUID, category: ReportCategory, details: String?)?
        var reportCommentCallCount = 0

        try await ReportContentView.report(
            target: .post(id: postID, hasPhoto: false), category: .harassment, details: "rude comment",
            reportPost: { id, category, details in reportPostCalled = (id, category, details) },
            reportComment: { _, _, _ in reportCommentCallCount += 1 }
        )

        XCTAssertEqual(reportPostCalled?.id, postID, "reportPost must receive the post's own id")
        XCTAssertEqual(reportPostCalled?.category, .harassment, "reportPost must receive the chosen category")
        XCTAssertEqual(reportPostCalled?.details, "rude comment", "reportPost must receive the typed details")
        XCTAssertEqual(reportCommentCallCount, 0,
                       "a .post target must never call reportComment")
    }

    /// The mirror image: a `.comment` target must call `reportComment` and must NEVER call
    /// `reportPost`. Combined with the test above, both repository calls firing for either target
    /// (the exact defect Step 6 proves is caught) fails at least one of this pair.
    func testCommentTargetRoutesToReportCommentAndNeverReportPost() async throws {
        let commentID = UUID()
        var reportCommentCalled: (id: UUID, category: ReportCategory, details: String?)?
        var reportPostCallCount = 0

        try await ReportContentView.report(
            target: .comment(id: commentID), category: .other, details: nil,
            reportPost: { _, _, _ in reportPostCallCount += 1 },
            reportComment: { id, category, details in reportCommentCalled = (id, category, details) }
        )

        XCTAssertEqual(reportCommentCalled?.id, commentID, "reportComment must receive the comment's own id")
        XCTAssertEqual(reportCommentCalled?.category, .other, "reportComment must receive the chosen category")
        XCTAssertNil(reportCommentCalled?.details, "nil details (no text typed) must be passed through as nil")
        XCTAssertEqual(reportPostCallCount, 0,
                       "a .comment target must never call reportPost")
    }

    /// Empty details in the composer must become `nil`, not an empty string, matching
    /// `ReportUserView.send()`'s identical `details.isEmpty ? nil : details` convention — this is
    /// exercised at the view's `send()` call site, not here, since `report(...)` itself is a dumb
    /// router that forwards whatever `details` it's given. Documented here so the convention isn't
    /// lost: `ReportContentView.send()` must perform this conversion before calling `report(...)`.
    func testReportForwardsDetailsExactlyAsGiven() async throws {
        let postID = UUID()
        var forwardedDetails: String??
        try await ReportContentView.report(
            target: .post(id: postID, hasPhoto: true), category: .inappropriatePostImage, details: "",
            reportPost: { _, _, details in forwardedDetails = details },
            reportComment: { _, _, _ in }
        )
        XCTAssertEqual(forwardedDetails, "", "report(...) forwards details verbatim; nil-conversion is send()'s job")
    }
}
