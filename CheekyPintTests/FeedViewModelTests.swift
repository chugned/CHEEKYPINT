import XCTest
import CheekyPintCore
@testable import CheekyPint

/// `FeedViewModel.toggleCheers`'s subtlest rule: two rapid Cheers taps by the same user converge
/// to un-cheered server-side (the RPC toggles, it doesn't set), so the view model must end up
/// matching whatever `toggle_post_cheers` actually returned — never the client's own optimistic
/// guess. A regression that keeps the optimistic value instead of reconciling from the response
/// is invisible to every other suite in this app (see the Task 3 report's broken-gate proof), so
/// this test injects a canned response that deliberately disagrees with the optimistic guess in
/// both fields and asserts the final state matches the response.
@MainActor
final class FeedViewModelTests: XCTestCase {

    func testToggleCheersReconcilesFromTheServerResponseNotTheOptimisticGuess() async throws {
        await DemoWorld.shared.activate(surname: "Alice")
        defer { Task { await DemoWorld.shared.deactivate() } }

        // An unreachable host, same defensive style as `FeedRepositoryTests`'s demo-mode test:
        // demo mode intercepts before any network call, but this makes "no real request is
        // possible" true by construction rather than by trusting that interception alone.
        let config = AppConfig(environment: .development,
                               supabaseURL: URL(string: "https://unreachable.invalid")!,
                               supabaseAnonKey: "k", universalHost: "unreachable.invalid")
        let container = AppContainer(config: config)

        let model = FeedViewModel(container: container, toggleCheers: { _ in
            // The optimistic guess for a post starting at (cheered: false, cheersCount: 0) is
            // (cheered: true, cheersCount: 1). This response disagrees with that guess in both
            // fields, so only a genuine reconcile-from-response can produce a match.
            ToggleCheersDTO(cheered: false, cheersCount: 7)
        })
        await model.load()

        guard let target = model.posts.first(where: { !$0.viewerHasCheered && $0.cheersCount == 0 }) else {
            XCTFail("expected a seeded post starting un-cheered with zero cheers")
            return
        }

        await model.toggleCheers(target)

        guard let updated = model.posts.first(where: { $0.id == target.id }) else {
            XCTFail("post disappeared after toggling")
            return
        }
        XCTAssertEqual(updated.viewerHasCheered, false,
                       "must match the server's response (false), not the optimistic guess (true)")
        XCTAssertEqual(updated.cheersCount, 7,
                       "must match the server's response (7), not the optimistic guess (1)")
    }

    /// The ordering half of the Cheers bug, left open by the reconciliation fix above: each tap
    /// used to spawn its own unguarded `Task`, so two rapid taps on the *same* post raced two
    /// requests over one HTTP/2 connection with no ordering guarantee. If the second request's
    /// reply (say, "off") landed before the first's ("on"), `reconcile` applied whichever arrived
    /// last — reconciling from a response doesn't help when the wrong response is the one that
    /// arrives last. `FeedViewModel` now tracks per-post in-flight state and ignores a tap on a
    /// post that already has one outstanding, which removes the race by construction: at most one
    /// request per post can ever be outstanding, so there is nothing left to arrive out of order.
    /// This test proves that by forcing two taps to overlap and asserting only one request fires;
    /// without the in-flight guard, both taps reach the injected closure and this fails 2 != 1.
    func testConcurrentCheersTapsOnTheSamePostIgnoreTheSecondWhileOneIsOutstanding() async throws {
        await DemoWorld.shared.activate(surname: "Alice")
        defer { Task { await DemoWorld.shared.deactivate() } }

        let config = AppConfig(environment: .development,
                               supabaseURL: URL(string: "https://unreachable.invalid")!,
                               supabaseAnonKey: "k", universalHost: "unreachable.invalid")
        let container = AppContainer(config: config)

        var callCount = 0
        let model = FeedViewModel(container: container, toggleCheers: { _ in
            callCount += 1
            // Long enough that, without the in-flight guard, a second concurrent tap reaches
            // this closure before the first call below has a chance to return.
            try await Task.sleep(nanoseconds: 100_000_000)
            return ToggleCheersDTO(cheered: true, cheersCount: 1)
        })
        await model.load()

        guard let target = model.posts.first else {
            XCTFail("expected at least one seeded post")
            return
        }

        // Two taps issued back-to-back, exactly as two fast taps on the same button would: each
        // becomes its own `Task` in `FeedView`'s `onToggleCheers` closure, with nothing between
        // them.
        async let first: Void = model.toggleCheers(target)
        async let second: Void = model.toggleCheers(target)
        _ = await (first, second)

        XCTAssertEqual(callCount, 1,
                       "a second tap on a post with a Cheers request already outstanding must be " +
                       "ignored rather than firing its own request")
    }

    /// `applyCommentCountDelta` is the fix for code review's "45 loaded 30, send → shows 31 when
    /// the truth is 46": `PostCommentsSheet`/`PostCommentsViewModel` only know how many comments
    /// *they* loaded, never the thread's real total, so the card's count must be adjusted by a
    /// delta rather than replaced. Seeds a post at `commentCount` 45 (deliberately not derived
    /// from anything the sheet loaded) and checks both directions survive round-tripping: +1 to
    /// 46, then -1 back to 45 — a delta applied twice must not compound incorrectly or clamp.
    func testApplyCommentCountDeltaAdjustsTheCardsCountInBothDirections() async throws {
        let config = AppConfig(environment: .development,
                               supabaseURL: URL(string: "https://unreachable.invalid")!,
                               supabaseAnonKey: "k", universalHost: "unreachable.invalid")
        let container = AppContainer(config: config)

        let postID = UUID()
        let seededPost = FeedPostDTO(
            postId: postID, authorId: UUID(), displayName: "Barnaby", avatarPath: nil,
            body: "a post with a long thread", imagePath: nil, placeLabel: nil, pubId: nil,
            createdAtRaw: "2026-08-12T12:00:00.000Z", cheersCount: 0, viewerHasCheered: false,
            commentCount: 45)

        let model = FeedViewModel(container: container, page: { _, _ in [seededPost] })
        await model.load()
        XCTAssertEqual(model.posts.first?.commentCount, 45, "seeded at the server's real total")

        model.applyCommentCountDelta(postID: postID, delta: 1)
        XCTAssertEqual(model.posts.first?.commentCount, 46,
                       "a confirmed send must add to the total (45 -> 46), not replace it with " +
                       "however many rows the sheet happened to have loaded")

        model.applyCommentCountDelta(postID: postID, delta: -1)
        XCTAssertEqual(model.posts.first?.commentCount, 45,
                       "a confirmed delete must subtract from the total (46 -> 45)")
    }

    // MARK: - deletePost

    /// The concrete regression this guards against: if `deletePost` forgot to remove the post from
    /// `posts` after a successful `delete_post`, the deleted post would linger in the feed until
    /// the next full refresh. Seeds two posts and deletes one, asserting the *other* one survives
    /// untouched — not just that the list shrank, which a bug that removed the wrong post could
    /// still pass.
    func testSuccessfulDeletePostRemovesItFromTheListAndLeavesOthersUntouched() async throws {
        let config = AppConfig(environment: .development,
                               supabaseURL: URL(string: "https://unreachable.invalid")!,
                               supabaseAnonKey: "k", universalHost: "unreachable.invalid")
        let container = AppContainer(config: config)

        func makePost(_ id: UUID, body: String) -> FeedPostDTO {
            FeedPostDTO(postId: id, authorId: UUID(), displayName: "Barnaby", avatarPath: nil,
                       body: body, imagePath: nil, placeLabel: nil, pubId: nil,
                       createdAtRaw: "2026-08-12T12:00:00.000Z", cheersCount: 0,
                       viewerHasCheered: false, commentCount: 0)
        }
        let toDelete = makePost(UUID(), body: "delete me")
        let keep = makePost(UUID(), body: "keep me")
        var deleteRequestedID: UUID?

        let model = FeedViewModel(container: container, page: { _, _ in [toDelete, keep] },
                                  deletePost: { id in deleteRequestedID = id })
        await model.load()
        XCTAssertEqual(model.posts.count, 2)

        await model.deletePost(model.posts.first { $0.id == toDelete.postId }!)

        XCTAssertEqual(deleteRequestedID, toDelete.postId, "delete_post must be called with the deleted post's id")
        XCTAssertEqual(model.posts.map(\.id), [keep.postId],
                       "only the deleted post must be removed; the other must survive untouched")
        XCTAssertNil(model.deleteError)
    }

    /// The asymmetric half: a rejected delete (e.g. the server's rate limit) must leave `posts`
    /// exactly as it was and must surface `deleteError` — a caller that removed the post from the
    /// list unconditionally (success or failure) would make the post vanish from the UI even
    /// though the server never actually deleted it.
    func testFailedDeletePostLeavesTheListUnchangedAndSurfacesAnError() async throws {
        let config = AppConfig(environment: .development,
                               supabaseURL: URL(string: "https://unreachable.invalid")!,
                               supabaseAnonKey: "k", universalHost: "unreachable.invalid")
        let container = AppContainer(config: config)

        let postID = UUID()
        let seeded = FeedPostDTO(postId: postID, authorId: UUID(), displayName: "Barnaby",
                                 avatarPath: nil, body: "stays put", imagePath: nil, placeLabel: nil,
                                 pubId: nil, createdAtRaw: "2026-08-12T12:00:00.000Z", cheersCount: 0,
                                 viewerHasCheered: false, commentCount: 0)

        let model = FeedViewModel(container: container, page: { _, _ in [seeded] },
                                  deletePost: { _ in throw SupabaseError.server(status: 429, message: "Too many requests") })
        await model.load()

        await model.deletePost(model.posts.first!)

        XCTAssertEqual(model.posts.map(\.id), [postID], "a failed delete must not remove the post")
        XCTAssertNotNil(model.deleteError, "a failed delete must surface an error")
    }

    /// The safety property `deletePost` actually depends on: the tombstone goes into
    /// `deletedPostIDs` **only after** `delete_post` has confirmed. Nothing else in this suite can
    /// fail if that ordering breaks —
    /// `testFailedDeletePostLeavesTheListUnchangedAndSurfacesAnError` never refreshes, so it never
    /// consults the tombstone set at all, and
    /// `testRefreshCannotResurrectAPostDeletedWhileItsPageRequestWasInFlight`'s delete is injected
    /// as a success, so it can't distinguish "inserted after confirmation" from "inserted before
    /// the request". Hoisting `deletedPostIDs.insert(post.id)` above
    /// `try await deletePostRequest(post.id)` leaves both of them green.
    ///
    /// What that regression costs in production: `delete_post` is rate-limited (60/hour), so a
    /// rejected delete is a routine outcome, not a hypothetical. With the insert hoisted, one
    /// rate-limited delete tombstones a post the server still holds, and `fetchFirstPage()` — which
    /// backs `load()` *and* `refresh()* — filters it out of every page for the rest of the process.
    /// (`fetchFirstPage()` is the shared body of both; `loadMore()` is unaffected by construction.)
    /// The post is live, visible to everyone else, and permanently invisible to its own author, who
    /// was just told the delete failed.
    ///
    /// The flip: a failed delete followed by a refresh. The injected `page` closure keeps returning
    /// the post — exactly what the server does, since it was never deleted — so the post must come
    /// back. Under the hoist the refresh filters it out and `posts` is empty.
    func testFailedDeleteDoesNotTombstoneThePostSoALaterRefreshStillShowsIt() async throws {
        let config = AppConfig(environment: .development,
                               supabaseURL: URL(string: "https://unreachable.invalid")!,
                               supabaseAnonKey: "k", universalHost: "unreachable.invalid")
        let container = AppContainer(config: config)

        let postID = UUID()
        let seeded = FeedPostDTO(postId: postID, authorId: UUID(), displayName: "Barnaby",
                                 avatarPath: nil, body: "never actually deleted", imagePath: nil,
                                 placeLabel: nil, pubId: nil, createdAtRaw: "2026-08-12T12:00:00.000Z",
                                 cheersCount: 0, viewerHasCheered: false, commentCount: 0)

        var deleteAttempts = 0
        let model = FeedViewModel(
            container: container,
            page: { _, _ in [seeded] },
            deletePost: { _ in
                deleteAttempts += 1
                // The realistic rejection: post_delete is capped at 60/hour, so the server keeps
                // the row and says no.
                throw SupabaseError.rateLimited(hint: "Please slow down and try again shortly.")
            })

        await model.load()
        XCTAssertEqual(model.posts.map(\.id), [postID], "sanity: the post is loaded before the delete")

        await model.deletePost(model.posts.first!)
        XCTAssertEqual(deleteAttempts, 1, "sanity: the delete was actually attempted")
        XCTAssertNotNil(model.deleteError, "sanity: the rejection surfaced")
        XCTAssertEqual(model.posts.map(\.id), [postID], "the rejected delete must leave the post in place")

        // The part no existing test reaches: the tombstone set is only consulted by
        // `fetchFirstPage()`, so the damage from a premature insert is invisible until a refresh.
        await model.refresh()

        XCTAssertEqual(model.posts.map(\.id), [postID],
                       "a post whose delete the server rejected must survive a refresh — a " +
                       "tombstone written before the server confirmed would filter a live post " +
                       "out of every fetchFirstPage for the rest of the session")
    }

    /// Code review's Important finding: `deletePost` and `refresh()` don't know about each other.
    /// `refresh()`'s `fetchFirstPage()` replaces `posts` wholesale from a fresh `feed_page` read —
    /// if that read is issued *before* `delete_post`'s `UPDATE ... deleted_at` commits, but its
    /// response is processed *after* `deletePost`'s own `removeAll`, the "deleted" post is written
    /// straight back into `posts`, silently contradicting the confirmation dialog's "This can't be
    /// undone."
    ///
    /// This drives that exact interleaving deterministically (no sleeps): the injected `page`
    /// closure suspends the *second* call (the refresh) on a `CheckedContinuation` until the test
    /// explicitly resumes it, so the delete's `removeAll` is guaranteed to run and complete first,
    /// and only then does the refresh's stale page — which still contains the "deleted" post,
    /// exactly as a `feed_page` read issued before `delete_post` committed would — get delivered.
    /// The flip point: without `deletedPostIDs` filtering `fetchFirstPage()`'s result, this stale
    /// page reinstates the deleted post and the final assertion fails.
    func testRefreshCannotResurrectAPostDeletedWhileItsPageRequestWasInFlight() async throws {
        let config = AppConfig(environment: .development,
                               supabaseURL: URL(string: "https://unreachable.invalid")!,
                               supabaseAnonKey: "k", universalHost: "unreachable.invalid")
        let container = AppContainer(config: config)

        func makePost(_ id: UUID, body: String) -> FeedPostDTO {
            FeedPostDTO(postId: id, authorId: UUID(), displayName: "Barnaby", avatarPath: nil,
                       body: body, imagePath: nil, placeLabel: nil, pubId: nil,
                       createdAtRaw: "2026-08-12T12:00:00.000Z", cheersCount: 0,
                       viewerHasCheered: false, commentCount: 0)
        }
        let toDelete = makePost(UUID(), body: "delete me")
        let other = makePost(UUID(), body: "stays")
        let page = [toDelete, other]

        var pageRequestCallCount = 0
        // Set by the second `pageRequest` call (the refresh) once it's suspended, waiting for the
        // test to let its "stale" response through. Both this and `pageRequestCallCount` above are
        // plain captured locals — the injected closure is MainActor-isolated (inferred from this
        // `@MainActor` test method), matching every other seam closure in this file
        // (`testConcurrentCheersTapsOnTheSamePostIgnoreTheSecondWhileOneIsOutstanding`'s
        // `callCount`, for instance) — so there is no cross-actor mutation here despite the
        // `async` suspension in between.
        var resumeStaleRefresh: CheckedContinuation<[FeedPostDTO], Never>?

        let model = FeedViewModel(
            container: container,
            page: { _, _ in
                pageRequestCallCount += 1
                if pageRequestCallCount == 1 { return page } // the initial load
                // The refresh: block here until the test resumes it, after the delete below has
                // already completed and removed the post locally.
                return await withCheckedContinuation { continuation in
                    resumeStaleRefresh = continuation
                }
            },
            deletePost: { _ in }
        )

        await model.load()
        XCTAssertEqual(Set(model.posts.map(\.id)), Set([toDelete.postId, other.postId]))

        let refreshTask = Task { await model.refresh() }
        // Deterministic, not timing-based: yield until the refresh's `pageRequest` call has
        // actually reached and suspended on the continuation above.
        while resumeStaleRefresh == nil { await Task.yield() }

        await model.deletePost(model.posts.first { $0.id == toDelete.postId }!)
        XCTAssertFalse(model.posts.contains { $0.id == toDelete.postId },
                       "the delete must remove the post locally before the stale refresh resolves")

        // Only now does the refresh's page — still containing the "deleted" post — arrive.
        resumeStaleRefresh?.resume(returning: page)
        await refreshTask.value

        XCTAssertFalse(model.posts.contains { $0.id == toDelete.postId },
                       "a stale refresh page containing an already-deleted post must not resurrect it")
        XCTAssertTrue(model.posts.contains { $0.id == other.postId },
                      "an unrelated post in the same stale page must still load normally")
    }
}
