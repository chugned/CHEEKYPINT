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
    /// response to `comments`, this fails — `model.comments.count` would stay at the seeded 2
    /// instead of 3, and the body/id assertions would fail.
    ///
    /// Deliberately seeds the thread with 2 already-loaded comments before sending (rather than
    /// starting empty) so this test actually distinguishes "report the delta" from "report the
    /// new absolute count" — with an empty start both would coincidentally read `1`. A thread
    /// with more comments than are loaded (the common case — `comments.count` is only however
    /// much has been paged in, never the server's real total) must still report `+1`, not `3`.
    func testSuccessfulSendAppendsTheCommentAndReportsAPlusOneDelta() async throws {
        await DemoWorld.shared.activate(surname: "Alice")
        defer { Task { await DemoWorld.shared.deactivate() } }

        let postID = UUID()
        let addedCommentID = UUID()
        let seeded = [makeComment(body: "already here 1", minsAgo: 10),
                      makeComment(body: "already here 2", minsAgo: 5)]
        var reportedDeltas: [Int] = []

        let model = PostCommentsViewModel(
            postID: postID, container: makeContainer(),
            onCommentCountChanged: { reportedDeltas.append($0) },
            comments: { _, _, _ in seeded },
            addComment: { _, body, _ in
                XCTAssertEqual(body, "Get in the car, Barnaby")
                return addedCommentID
            }
        )
        await model.load()
        XCTAssertEqual(model.comments.count, 2, "two comments loaded before sending")

        let sent = await model.send(rawBody: "Get in the car, Barnaby", mentions: [:])

        XCTAssertTrue(sent, "a send with no injected failure must report success")
        XCTAssertEqual(model.comments.count, 3, "the new comment must be appended locally")
        XCTAssertEqual(model.comments.last?.id, addedCommentID,
                       "the appended comment must carry the id the server returned")
        XCTAssertEqual(model.comments.last?.body, "Get in the car, Barnaby")
        XCTAssertEqual(reportedDeltas, [1],
                       "onCommentCountChanged must report a +1 delta, not the new loaded count (3)")
        XCTAssertNil(model.sendError)
    }

    /// The mirror image on the delete side: reports `-1`, not `comments.count` after removal
    /// (which would again be the wrong number whenever the thread has more comments than loaded).
    func testSuccessfulDeleteRemovesTheCommentAndReportsAMinusOneDelta() async throws {
        await DemoWorld.shared.activate(surname: "Alice")
        defer { Task { await DemoWorld.shared.deactivate() } }

        let postID = UUID()
        let toDelete = makeComment(body: "delete me", minsAgo: 10)
        let keep = makeComment(body: "keep me", minsAgo: 5)
        var reportedDeltas: [Int] = []
        var deleteRequestedID: UUID?

        let model = PostCommentsViewModel(
            postID: postID, container: makeContainer(),
            onCommentCountChanged: { reportedDeltas.append($0) },
            comments: { _, _, _ in [toDelete, keep] },
            deleteComment: { id in deleteRequestedID = id }
        )
        await model.load()
        XCTAssertEqual(model.comments.count, 2)

        await model.delete(toDelete)

        XCTAssertEqual(deleteRequestedID, toDelete.id)
        XCTAssertEqual(model.comments.map(\.id), [keep.id], "only the deleted comment must be removed")
        XCTAssertEqual(reportedDeltas, [-1], "onCommentCountChanged must report a -1 delta")
        XCTAssertNil(model.sendError)
    }

    /// A failed delete must not touch `comments` or report any delta — mirrors the failed-send
    /// test below.
    func testFailedDeleteLeavesTheListUnchangedAndDoesNotReportACountChange() async throws {
        await DemoWorld.shared.activate(surname: "Alice")
        defer { Task { await DemoWorld.shared.deactivate() } }

        let postID = UUID()
        let seeded = makeComment(body: "stays put")
        var callCount = 0

        let model = PostCommentsViewModel(
            postID: postID, container: makeContainer(),
            onCommentCountChanged: { _ in callCount += 1 },
            comments: { _, _, _ in [seeded] },
            deleteComment: { _ in throw SupabaseError.server(status: 400, message: "Comment not available") }
        )
        await model.load()

        await model.delete(seeded)

        XCTAssertEqual(model.comments.map(\.id), [seeded.id], "a failed delete must not remove the comment")
        XCTAssertNotNil(model.sendError, "a failed delete must surface an error")
        XCTAssertEqual(callCount, 0, "onCommentCountChanged must not fire when the delete failed")
    }

    /// Code review's minor finding: mentions must be resolved before the 280-char clamp, not
    /// after — otherwise a comment whose mention lands right at the boundary can have its name
    /// cut mid-word by truncation, silently dropping a mention the user clearly finished typing.
    /// This builds a raw body of exactly 300 characters ending in a full, real mention name, so
    /// truncating-then-scanning (the bug) would see `"...@Barnaby Pemberton-Sm"` (name cut mid-
    /// word, no longer a match) while scanning-then-truncating (the fix) sees the complete name
    /// before any cut is applied.
    func testMentionSurvivesEvenWhenTruncationWouldCutItsNameMidWord() async throws {
        await DemoWorld.shared.activate(surname: "Alice")
        defer { Task { await DemoWorld.shared.deactivate() } }

        let postID = UUID()
        let barnaby = UUID()
        let mentionSuffix = "@Barnaby Pemberton-Smythe"
        // Pad so the full raw body is 300 characters — comfortably past the 280-char server clamp
        // — with the mention landing exactly at the tail, spanning the clamp boundary.
        let padding = String(repeating: "x", count: 300 - mentionSuffix.count - 1)
        let rawBody = padding + " " + mentionSuffix
        XCTAssertEqual(rawBody.count, 300)

        var sentMentions: [UUID]?
        let model = PostCommentsViewModel(
            postID: postID, container: makeContainer(),
            onCommentCountChanged: { _ in },
            comments: { _, _, _ in [] },
            addComment: { _, body, mentions in
                XCTAssertEqual(body.count, PostCommentsViewModel.bodyLimit,
                               "the body actually sent must still respect the server's clamp")
                sentMentions = mentions
                return UUID()
            }
        )
        await model.load()

        _ = await model.send(rawBody: rawBody, mentions: [barnaby: "Barnaby Pemberton-Smythe"])

        XCTAssertEqual(sentMentions, [barnaby],
                       "a mention whose name is intact in the raw text must survive truncation " +
                       "of the text actually sent")
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

    /// Code review's Critical finding: sending a comment appends a locally-built echo (see
    /// `send()`) to `comments`, and that echo's timestamp is the client's own `Date()` — always
    /// later than every real, server-returned comment. A `loadMore()` that derives its cursor from
    /// `comments.last` (rather than from the last comment the *server* actually returned) would
    /// therefore cursor from the echo after a send, not from `c3`. Concretely: a 45-comment thread
    /// loads page one (comments 1–30, `pageSize` 30 here shrunk to 3 for the test), the user sends
    /// a comment (appending the echo after `c3`), then scrolls to load more — the fix must still
    /// send `c3`'s cursor, not the echo's, or `c4` becomes permanently unreachable (the server's
    /// `(created_at, id) > cursor` would find nothing newer than the echo and return `[]`).
    func testSendingACommentThenPagingCursorsFromTheLastServerCommentNotTheLocalEcho() async throws {
        await DemoWorld.shared.activate(surname: "Alice")
        defer { Task { await DemoWorld.shared.deactivate() } }

        let postID = UUID()
        let c1 = makeComment(body: "one", minsAgo: 30)
        let c2 = makeComment(body: "two", minsAgo: 20)
        let c3 = makeComment(body: "three (boundary)", minsAgo: 10)
        let c4 = makeComment(body: "four (only reachable via the real cursor)", minsAgo: 5)

        var secondPageCursor: FeedCursor?
        let model = PostCommentsViewModel(
            postID: postID, container: makeContainer(), pageSize: 3,
            onCommentCountChanged: { _ in },
            comments: { _, cursor, _ in
                if cursor == nil { return [c1, c2, c3] }
                secondPageCursor = cursor
                // Mirrors the real `(created_at, id) > cursor` server filter: only the correct
                // cursor (c3's) yields c4. Any other cursor — in particular the locally-appended
                // echo's, which sorts after everything — finds nothing newer and returns `[]`,
                // exactly like production would. This makes the `contains(c4)` assertion below a
                // second, independently-failing check of the same property the cursor-equality
                // assertion checks, rather than a redundant assertion that would pass either way
                // (an earlier version of this stub returned `[c4]` unconditionally, which made
                // that assertion true regardless of which cursor was actually sent).
                return cursor == c3.cursor ? [c4] : []
            },
            addComment: { _, _, _ in UUID() }
        )

        await model.load()
        XCTAssertTrue(model.hasMore)

        // Send BEFORE paging — the echo's `Date()` timestamp sorts after every seeded comment,
        // so it becomes `comments.last` if the cursor is (wrongly) taken from there.
        let sent = await model.send(rawBody: "sent before paging", mentions: [:])
        XCTAssertTrue(sent)

        await model.loadMore()

        XCTAssertEqual(secondPageCursor, c3.cursor,
                       "loadMore must cursor from c3 (the last server-returned comment), " +
                       "never from the locally-appended echo")
        XCTAssertTrue(model.comments.contains { $0.id == c4.id },
                      "c4 must still be reachable after a send — a cursor derived from the echo " +
                      "would make the server return [] and strand it forever")
    }
}
