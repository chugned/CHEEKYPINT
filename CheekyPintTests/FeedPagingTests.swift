import XCTest
import CheekyPintCore
@testable import CheekyPint

/// "Untested #1" from the branch review: demo mode seeded only 3 posts against a `pageSize` of
/// 20, so `hasMore` was always false and `loadMore` returned at its own guard on every call —
/// cursor selection, the append, and `hasMore` recomputation had zero execution in any suite,
/// despite paging being the feed's headline data-path claim. These tests exercise all three,
/// using the `page` injection seam on `FeedViewModel.init` (mirroring the existing `toggleCheers`
/// seam) for full control over what each page contains, plus one end-to-end test against the
/// real (now-larger) `DemoWorld` seed.
@MainActor
final class FeedPagingTests: XCTestCase {

    private func container() -> AppContainer {
        // An unreachable host, same defensive style as `FeedViewModelTests`: the `page` seam
        // intercepts before any network call, but this makes "no real request is possible" true
        // by construction rather than by trusting that interception alone.
        let config = AppConfig(environment: .development,
                               supabaseURL: URL(string: "https://unreachable.invalid")!,
                               supabaseAnonKey: "k", universalHost: "unreachable.invalid")
        return AppContainer(config: config)
    }

    private func post(id: UUID = UUID(), createdAtRaw: String) -> FeedPostDTO {
        FeedPostDTO(postId: id, authorId: UUID(), displayName: "Test", avatarPath: nil,
                   body: "body", imagePath: nil, placeLabel: nil, pubId: nil,
                   createdAtRaw: createdAtRaw, cheersCount: 0, viewerHasCheered: false,
                   commentCount: 0)
    }

    /// `feed_page` orders `(created_at, id)` descending, so the cursor for the *next* page must
    /// be the *last* (oldest) post of the page just received — and it must carry that post's raw
    /// `created_at` string byte-for-byte, not a value reparsed through `Date` (which would lose
    /// sub-second precision and land the cursor between tied rows, silently dropping posts — see
    /// `FeedRepositoryTests`'s cursor-encoding tests for the same rule one layer down).
    func testLoadMoreSendsTheFirstPagesLastPostsCursorByteForByte() async throws {
        let firstPage = [
            post(createdAtRaw: "2026-08-11T19:46:03.912340+02:00"),
            post(createdAtRaw: "2026-08-11T19:46:01.334760+02:00"),
        ]
        var receivedCursors: [FeedCursor?] = []
        let model = FeedViewModel(container: container(), pageSize: 2, page: { cursor, limit in
            receivedCursors.append(cursor)
            XCTAssertEqual(limit, 2)
            return receivedCursors.count == 1 ? firstPage : []
        })

        await model.load()
        XCTAssertEqual(receivedCursors.count, 1)
        XCTAssertNil(receivedCursors[0], "the first page must send a nil cursor")

        await model.loadMore()
        XCTAssertEqual(receivedCursors.count, 2, "loadMore must have issued a second page request")
        XCTAssertEqual(receivedCursors[1]?.createdAt, firstPage.last!.createdAtRaw,
                       "loadMore's cursor must be the first page's LAST post's raw timestamp, byte-for-byte")
        XCTAssertEqual(receivedCursors[1]?.postID, firstPage.last!.postId,
                       "the cursor's id half must match too — created_at alone can tie")
    }

    /// `20260811000500_rpc_feed_posts.sql` accepts "may repeat a tied row across pages" as a
    /// failure mode *on the assumption the client dedupes by id* — it didn't. This response
    /// deliberately repeats a row from the first page to prove the client now does.
    func testLoadMoreAppendsWithoutDuplicatingARowRepeatedAcrossPages() async throws {
        let repeatedID = UUID()
        let firstPage = [
            post(createdAtRaw: "2026-08-11T19:46:05.000000+02:00"),
            post(id: repeatedID, createdAtRaw: "2026-08-11T19:46:03.000000+02:00"),
        ]
        let secondPage = [
            post(id: repeatedID, createdAtRaw: "2026-08-11T19:46:03.000000+02:00"),
            post(createdAtRaw: "2026-08-11T19:46:01.000000+02:00"),
        ]
        var callCount = 0
        let model = FeedViewModel(container: container(), pageSize: 2, page: { _, _ in
            callCount += 1
            return callCount == 1 ? firstPage : secondPage
        })

        await model.load()
        await model.loadMore()

        let ids = model.posts.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "no id should appear more than once, got: \(ids)")
        XCTAssertEqual(model.posts.count, 3,
                       "3 distinct posts across both pages — the repeated row must collapse to one")
    }

    /// End-to-end against the real demo backend (no injected seam): `DemoWorld` now seeds more
    /// posts than `FeedViewModel`'s default `pageSize` (20) specifically so this path — a real
    /// non-nil cursor round-tripping through `DemoWorld.feedPage`'s own `(createdAt, id)` cursor
    /// comparison — actually runs somewhere, which it never did before this fix.
    func testLoadMoreAgainstRealDemoDataAppendsBeyondPageOneWithoutDuplicates() async throws {
        await DemoWorld.shared.activate(surname: "Alice")
        defer { Task { await DemoWorld.shared.deactivate() } }

        let model = FeedViewModel(container: container())
        await model.load()
        XCTAssertEqual(model.posts.count, 20, "page one should be a full page")
        XCTAssertTrue(model.hasMore, "23 seeded posts is more than one page of 20")

        await model.loadMore()
        XCTAssertEqual(model.posts.count, 23, "page two should append the remaining seeded posts")
        XCTAssertFalse(model.hasMore, "a short second page means there is nothing further")

        let ids = model.posts.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "no duplicate ids across the two real pages")
    }
}
