import XCTest
import CheekyPintCore
@testable import CheekyPint

/// `PostCommentsViewModel` follows `FeedViewModel`'s seam style: injectable closures built in the
/// `init` body (never as default-parameter expressions — Swift cannot reference a sibling
/// parameter like `container` there) so a test can control exactly what the "server" replies
/// without a protocol hierarchy or a mock framework.
@MainActor
final class PostCommentsViewModelTests: XCTestCase {

    private func makeContainer() -> AppContainer {
        let config = AppConfig(environment: .development,
                               supabaseURL: URL(string: "https://unreachable.invalid")!,
                               supabaseAnonKey: "k", universalHost: "unreachable.invalid")
        return AppContainer(config: config)
    }

    private func makeComment(body: String = "hi", minsAgo: Double = 0,
                             mentionedUserIds: [UUID] = []) -> PostCommentDTO {
        let raw = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            .format(Date().addingTimeInterval(-minsAgo * 60))
        return PostCommentDTO(commentId: UUID(), authorId: DemoWorld.barnabyID, displayName: "Barnaby",
                              avatarPath: nil, body: body, createdAtRaw: raw, mentionedUserIds: mentionedUserIds)
    }

    // MARK: - Successful send

    /// A concrete regression this guards against: if `send` forgot to append the server's
    /// response to `comments`, or forgot to call `onCommentCountChanged`, this fails —
    /// `finalCount` would stay `nil` and the count assertion would fail; `model.comments.count`
    /// would stay 0 and the body assertion would fail.
    func testSuccessfulSendAppendsTheCommentAndReportsTheNewCount() async throws {
        await DemoWorld.shared.activate(surname: "Alice")
        defer { Task { await DemoWorld.shared.deactivate() } }

        let postID = UUID()
        let addedCommentID = UUID()
        var reportedCounts: [Int] = []

        let model = PostCommentsViewModel(
            postID: postID, container: makeContainer(),
            onCommentCountChanged: { reportedCounts.append($0) },
            comments: { _, _, _ in [] },
            addComment: { _, body, _ in
                XCTAssertEqual(body, "Get in the car, Barnaby")
                return addedCommentID
            }
        )
        await model.load()
        XCTAssertEqual(model.comments.count, 0, "no comments before sending")

        let sent = await model.send(rawBody: "Get in the car, Barnaby", mentions: [:])

        XCTAssertTrue(sent, "a send with no injected failure must report success")
        XCTAssertEqual(model.comments.count, 1, "the new comment must be appended locally")
        XCTAssertEqual(model.comments.last?.id, addedCommentID,
                       "the appended comment must carry the id the server returned")
        XCTAssertEqual(model.comments.last?.body, "Get in the car, Barnaby")
        XCTAssertEqual(reportedCounts, [1], "onCommentCountChanged must report the new total, once")
        XCTAssertNil(model.sendError)
    }

    // MARK: - Failed send

    /// The asymmetric half of the above: a rejected send (the server's `add_comment` raises for
    /// e.g. a non-friend mention) must leave `comments` exactly as it was and must NOT call
    /// `onCommentCountChanged` — a caller (`FeedPostCard`'s count) trusts that callback completely,
    /// so a spurious call on failure would show an incremented count for a comment that was never
    /// actually created. `callCount` starting at 0 and staying 0 is the concrete flip point: an
    /// implementation that called the callback unconditionally after every `addCommentRequest`
    /// (success or failure) would drive it to 1 and fail this assertion.
    func testFailedSendLeavesTheListUnchangedAndDoesNotReportACountChange() async throws {
        await DemoWorld.shared.activate(surname: "Alice")
        defer { Task { await DemoWorld.shared.deactivate() } }

        let postID = UUID()
        let seeded = makeComment(body: "already here")
        var callCount = 0

        let model = PostCommentsViewModel(
            postID: postID, container: makeContainer(),
            onCommentCountChanged: { _ in callCount += 1 },
            comments: { _, _, _ in [seeded] },
            addComment: { _, _, _ in
                throw SupabaseError.server(status: 400, message: "Can only mention friends")
            }
        )
        await model.load()
        XCTAssertEqual(model.comments.count, 1)

        let sent = await model.send(rawBody: "@AStranger nice one", mentions: [:])

        XCTAssertFalse(sent, "a send whose addCommentRequest throws must report failure")
        XCTAssertEqual(model.comments.count, 1, "a failed send must not add a comment")
        XCTAssertEqual(model.comments.first?.id, seeded.id, "the existing comment must be untouched")
        XCTAssertNotNil(model.sendError, "a failed send must surface an error")
        XCTAssertEqual(callCount, 0, "onCommentCountChanged must not fire when the send failed")
    }

    // MARK: - Paging

    /// Mirrors `FeedViewModel`'s own dedup test: `post_comments_page` can repeat the boundary row
    /// across two pages (a tied `(created_at, id)` cursor with an incomplete follow-up), and the
    /// view model must both keep that row exactly once (not duplicate it) and still pick up
    /// whatever page two adds beyond it (not drop it). Page one is deliberately the full
    /// `pageSize` (3) so `hasMore` flips true and a `loadMore()` is actually reachable; page two
    /// deliberately repeats page one's last id before adding a new one.
    func testPagingWithACursorNeitherDuplicatesNorDropsTheBoundaryComment() async throws {
        await DemoWorld.shared.activate(surname: "Alice")
        defer { Task { await DemoWorld.shared.deactivate() } }

        let postID = UUID()
        let c1 = makeComment(body: "one", minsAgo: 30)
        let c2 = makeComment(body: "two", minsAgo: 20)
        let c3 = makeComment(body: "three (boundary)", minsAgo: 10)
        let c4 = makeComment(body: "four", minsAgo: 5)

        var receivedCursors: [FeedCursor?] = []
        let model = PostCommentsViewModel(
            postID: postID, container: makeContainer(), pageSize: 3,
            onCommentCountChanged: { _ in },
            comments: { _, cursor, _ in
                receivedCursors.append(cursor)
                if cursor == nil { return [c1, c2, c3] }
                // The documented, accepted `post_comments_page` failure mode: the boundary row
                // (`c3`) can be repeated at the head of the next page.
                return [c3, c4]
            }
        )

        await model.load()
        XCTAssertEqual(model.comments.map(\.id), [c1.id, c2.id, c3.id])
        XCTAssertTrue(model.hasMore, "a full first page must report more available")

        await model.loadMore()

        XCTAssertEqual(receivedCursors.count, 2, "loadMore must have issued a second request")
        XCTAssertEqual(receivedCursors.last, c3.cursor,
                       "the second request must cursor from the last comment already shown")
        XCTAssertEqual(model.comments.map(\.id), [c1.id, c2.id, c3.id, c4.id],
                       "c3 must appear exactly once and c4 must not be dropped")
        XCTAssertFalse(model.hasMore, "a short second page (2 < pageSize 3) must end paging")
    }
}
