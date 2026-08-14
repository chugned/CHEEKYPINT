import SwiftUI
import CheekyPintCore

/// A feed row's mutable display state, layered over the immutable `FeedPostDTO` the server sent.
///
/// `FeedPostDTO` is deliberately `let`-only (see `RPCContracts.swift`) — it is a decoded network
/// response, not app state. Rather than mutate it by re-decoding, or loosen its fields to `var`
/// (which would blur "what the server said" with "what the UI is doing right now" for every
/// consumer, not just this screen), the Cheers toggle's two mutable fields live in this small
/// wrapper. Everything else is read straight from the wrapped `post`.
struct FeedPostState: Identifiable, Sendable {
    let post: FeedPostDTO
    var viewerHasCheered: Bool
    var cheersCount: Int
    /// Mirrors `viewerHasCheered`/`cheersCount`'s reasoning: `post.commentCount` is the server's
    /// count as of the last page fetch, but `PostCommentsSheet` (opened from `FeedPostCard`) can
    /// add or remove comments without a full feed refetch, so this mutable copy is what the card
    /// actually displays — adjusted via `FeedViewModel.applyCommentCountDelta(postID:delta:)`.
    var commentCount: Int

    init(_ post: FeedPostDTO) {
        self.post = post
        self.viewerHasCheered = post.viewerHasCheered
        self.cheersCount = post.cheersCount
        self.commentCount = post.commentCount
    }

    var id: UUID { post.postId }
    var cursor: FeedCursor { post.cursor }
}

/// Drives the Feed tab. Matches `HomeViewModel`'s shape: a `@MainActor @Observable` class that
/// orchestrates loading/paging and leaves all counting/formatting to the view.
@MainActor
@Observable
final class FeedViewModel {
    let container: AppContainer

    private(set) var posts: [FeedPostState] = []
    private(set) var isLoading = false
    private(set) var loadError: SupabaseError?
    private(set) var hasMore = true

    /// Surfaced separately from `loadError`: a failed Cheers toggle shouldn't blank an
    /// already-loaded feed into the full-screen error state. Rendered by `FeedView` as an inline
    /// message (matching `ComposePostSheet`/`PostCommentsSheet`/`ReportContentView`/
    /// `DataExportView`'s inline error `Text`s), not a system `.alert` — a modal alert triggered
    /// from a plain `Button`'s directly-invoked `Task` proved unreliable to present (see
    /// `docs/STATE_AUDIT.md`'s "Fixes applied" section), and inline text has no such presentation
    /// step to fail. Cleared at the start of the next `toggleCheers` attempt, the same
    /// clear-on-retry convention those four screens use, since there's no longer a standalone
    /// dismiss button.
    var cheersError: String?

    /// Mirrors `cheersError`'s reasoning for a failed post deletion — a transient alert, not a
    /// full-screen error, since the rest of the feed is still perfectly valid.
    var deleteError: String?

    private let pageSize: Int

    /// The one seam this view model needs for testing Cheers: how a Cheers tap is sent. Defaults
    /// to the real repository call; a test can inject a canned response instead, without a
    /// protocol hierarchy or a mock framework, to prove reconciliation reads from *that* response
    /// rather than from the optimistic guess computed before it arrives.
    private let toggleCheersRequest: (UUID) async throws -> ToggleCheersDTO

    /// The seam for testing paging, mirroring `toggleCheersRequest` above. Defaults to the real
    /// repository call; a test can inject canned pages to assert the cursor sent on the *second*
    /// call is the first page's last post's `createdAtRaw` byte-for-byte, and that appending a
    /// page that repeats a row (the documented, accepted `feed_page` failure mode — see
    /// `20260811000500_rpc_feed_posts.sql`) doesn't duplicate it client-side.
    private let pageRequest: (FeedCursor?, Int) async throws -> [FeedPostDTO]

    /// The seam for testing post deletion, mirroring `toggleCheersRequest`/`pageRequest` above.
    private let deletePostRequest: (UUID) async throws -> Void

    /// Posts with a Cheers toggle currently in flight. Each tap used to spawn an independent,
    /// unguarded `Task`, so two rapid taps on the same post raced two requests over one HTTP/2
    /// connection with no ordering guarantee — if the second request (say, the "un-cheer") landed
    /// before the first ("cheer"), `reconcile` would apply whichever arrived last and leave the UI
    /// showing the opposite of what the server actually holds. Reconciling from the response (the
    /// earlier fix) closed "trusting the optimistic guess"; it did nothing about "two requests
    /// racing" — this set closes that: a tap on a post already in this set is ignored outright
    /// rather than firing a second request that could return out of order. A monotonic sequence
    /// number checked in `reconcile` was the other option considered; ignoring is simpler and
    /// removes the race by construction instead of merely detecting and discarding a stale reply,
    /// and a toggle mid-flight has no well-defined "what should a second tap even do" answer to
    /// preserve by queuing or coalescing it.
    private var cheersInFlight: Set<UUID> = []

    /// Posts currently being deleted, so a second invocation while one is already in flight is
    /// ignored rather than firing a duplicate `delete_post` — same reasoning as `cheersInFlight`.
    private var deletingPostIDs: Set<UUID> = []

    /// Ids the viewer has successfully deleted this session. Closes a race between `deletePost`
    /// and `refresh()`: `refresh()`'s `fetchFirstPage()` replaces `posts` wholesale from a fresh
    /// `feed_page` read, and if that read is issued *before* `delete_post`'s `UPDATE ...
    /// deleted_at` commits but its response is processed *after* `deletePost`'s own `removeAll`,
    /// the "deleted" post is written straight back into `posts` — silently contradicting
    /// `FeedPostCard`'s "This can't be undone" confirmation. `fetchFirstPage()` filters this set
    /// out of every page it assigns, including a plain `load()`, so a resurrected row can never
    /// stick even if it briefly reappears in a server response mid-race.
    ///
    /// `loadMore()`'s `appendDeduplicated` path deliberately does **not** consult this set: its
    /// cursor is always strictly older than the last row already shown, so an already-visible
    /// deleted post can never re-enter through it — the race is specific to a full replace.
    ///
    /// Bounded by how many posts this viewer deletes before the app process ends, not by feed
    /// size — for the handful of deletes a real session sees, that's noise; there's no eviction
    /// because nothing here ever needs to forget a delete before the process restarts anyway.
    private var deletedPostIDs: Set<UUID> = []

    /// A `reload()` that arrived while another load was in flight and must not be lost.
    ///
    /// `reload()` delegates to the same page-one fetch as `refresh()`, and that fetch is guarded by
    /// `isLoading` — the flag that makes `refresh()` and `loadMore()` mutually exclusive (see
    /// `refresh()`'s doc for the `p21...p40` drop it was added to fix). Dropping the request is the
    /// right answer for a pull-to-refresh, because the user is holding the gesture and can simply
    /// pull again. It is the wrong answer for a post-compose reload: by then the composer has
    /// dismissed, the post exists server-side, and there is no spinner, no error and nothing on
    /// screen to retry. Concretely — scroll to the bottom of the feed so `loadMore()` is in flight
    /// on a slow connection, then compose and post: the new post is simply absent until the user
    /// happens to pull to refresh.
    ///
    /// A `Bool` rather than a counter on purpose: N reloads that arrive during one in-flight load
    /// collapse into one page-one fetch, which surfaces all of them.
    private var pendingReload = false

    init(container: AppContainer, pageSize: Int = 20,
         toggleCheers: ((UUID) async throws -> ToggleCheersDTO)? = nil,
         page: ((FeedCursor?, Int) async throws -> [FeedPostDTO])? = nil,
         deletePost: ((UUID) async throws -> Void)? = nil) {
        self.container = container
        self.pageSize = pageSize
        self.toggleCheersRequest = toggleCheers ?? { try await container.feed.toggleCheers(postID: $0) }
        self.pageRequest = page ?? { cursor, limit in try await container.feed.page(before: cursor, limit: limit) }
        self.deletePostRequest = deletePost ?? { try await container.feed.deletePost($0) }
    }

    /// First load. Clears any existing posts up front so a retry after an error doesn't show
    /// stale content next to the error state. Guarded by the same `isLoading` flag as `refresh()`
    /// and `loadMore()` (see the note there) so this can't race either of them.
    ///
    /// Each of the three public load entry points is a thin `perform…` + `drainPendingReload()`
    /// pair. The split exists so the `isLoading` flag can be released by `defer` inside the
    /// `perform…` body (which is what makes it exception-safe) *before* the drain runs — a drain
    /// inside that scope would see `isLoading` still true and skip itself.
    func load() async {
        await performLoad()
        await drainPendingReload()
    }

    private func performLoad() async {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        posts = []
        defer { isLoading = false }
        await fetchFirstPage()
    }

    /// Pull-to-refresh. Same first page as `load()`, but posts are only replaced once the new
    /// page arrives, so the list doesn't flash empty while it's in flight.
    ///
    /// Shares `isLoading` with `load()`/`loadMore()` — it used to not set the flag at all, so it
    /// sailed straight past `loadMore`'s in-flight guard. A user paged to cursor p40, still
    /// waiting on a slow `loadMore` reply, who pulled to refresh would see `refresh` land first
    /// and replace `posts` with `[p1...p20]`; `loadMore`'s reply then arrived and appended
    /// `p41...p60` on top of that, silently dropping `p21...p40`. One shared flag makes `refresh`
    /// and `loadMore` mutually exclusive instead of two independent writers to the same array.
    func refresh() async {
        await performRefresh()
        await drainPendingReload()
    }

    private func performRefresh() async {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        await fetchFirstPage()
    }

    /// Called after a successful compose (`ComposePostSheet.onPosted`). A freshly created post
    /// sorts to the head of the feed by `created_at`, so re-fetching page one — the same fetch
    /// `refresh()` already does for pull-to-refresh — is enough to surface it, with no separate
    /// "prepend one post locally" path that could drift from the server's own ordering/dedup.
    ///
    /// Unlike `refresh()` this must not be silently dropped when a load is already in flight: see
    /// `pendingReload`'s doc. If one is, the request is recorded and run by whichever load is
    /// holding `isLoading`, as soon as it releases it.
    func reload() async {
        guard !isLoading else {
            pendingReload = true
            return
        }
        await performRefresh()
        await drainPendingReload()
    }

    /// Runs a `reload()` that `pendingReload` recorded, once nothing else is loading.
    ///
    /// A `while` rather than an `if`: the fetch below suspends, so another `reload()` can arrive
    /// during it and set the flag again. This cannot spin — the condition only becomes true again
    /// when an external caller sets it, never as a side effect of the loop body.
    private func drainPendingReload() async {
        while pendingReload, !isLoading {
            pendingReload = false
            await performRefresh()
        }
    }

    private func fetchFirstPage() async {
        do {
            let page = try await pageRequest(nil, pageSize)
            // Filter before assigning — see `deletedPostIDs`'s doc for the exact race this closes.
            posts = page.filter { !deletedPostIDs.contains($0.postId) }.map(FeedPostState.init)
            hasMore = page.count == pageSize
        } catch let cancellation where cancellation.isCancellation {
            // Switching tabs cancels this screen's `.task` mid-fetch (see `FeedView`). That's an
            // interruption, not a failure the user asked about — leaving `loadError`/`posts`
            // untouched (rather than the generic "Couldn't load the feed") means returning to the
            // tab sees an empty, error-free state and `FeedView` retries cleanly instead of
            // flashing a stale network error it never actually had.
        } catch let error as SupabaseError {
            loadError = error
        } catch {
            loadError = .unknown("Couldn't load the feed.")
        }
    }

    /// Infinite scroll. No-op while a load is already in flight or once a short page has said
    /// there is nothing more. Appends with de-duplication by id: `feed_page`'s compound
    /// `(created_at, id)` cursor can still repeat a tied row across pages by design when a caller
    /// sends an incomplete cursor (see the SQL migration's own note), and that failure mode is
    /// only "recoverable client-side" if the client actually dedupes — it didn't.
    func loadMore() async {
        await performLoadMore()
        await drainPendingReload()
    }

    private func performLoadMore() async {
        guard !isLoading, hasMore, let cursor = posts.last?.cursor else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await pageRequest(cursor, pageSize)
            posts.appendDeduplicated(page.map(FeedPostState.init))
            hasMore = page.count == pageSize
        } catch let cancellation where cancellation.isCancellation {
            // See the matching catch in `fetchFirstPage()` — a cancelled page fetch (e.g. the
            // screen disappearing mid-scroll) isn't a failure worth surfacing in the footer.
        } catch let error as SupabaseError {
            loadError = error
        } catch {
            loadError = .unknown("Couldn't load more posts.")
        }
    }

    /// Optimistic with rollback. Flips the local guess immediately for a responsive tap, then
    /// **reconciles from the server's response** rather than trusting that guess — two rapid
    /// taps by the same user converge to un-cheered server-side by design (the RPC toggles,
    /// it doesn't set), so if the client kept its own optimistic value instead of the returned
    /// `cheered`/`cheersCount`, a double-tap would leave the UI showing "cheered" while the
    /// server actually landed on "not cheered". On failure, the optimistic flip is rolled back
    /// and the error is surfaced without disturbing the rest of the feed.
    ///
    /// Ignores a tap on a post that already has one outstanding (see `cheersInFlight`'s doc) —
    /// reconciling from *a* response doesn't help if the wrong one arrives last.
    func toggleCheers(_ post: FeedPostState) async {
        guard let index = posts.firstIndex(where: { $0.id == post.id }) else { return }
        guard !cheersInFlight.contains(post.id) else { return }
        cheersInFlight.insert(post.id)
        defer { cheersInFlight.remove(post.id) }
        // Cleared on entry, matching every other inline-error surface in this app (`submit()`/
        // `send()`/`export()` all clear their own error the same way) — `cheersError` is now
        // rendered as an inline message in `FeedView`, not a dismiss-button alert, so a fresh
        // attempt is the only thing that clears a stale one.
        cheersError = nil

        let previousCheered = posts[index].viewerHasCheered
        let previousCount = posts[index].cheersCount
        posts[index].viewerHasCheered.toggle()
        posts[index].cheersCount = max(0, previousCount + (posts[index].viewerHasCheered ? 1 : -1))

        do {
            let result = try await toggleCheersRequest(post.id)
            reconcile(postID: post.id, cheered: result.cheered, cheersCount: result.cheersCount)
        } catch let error as SupabaseError {
            reconcile(postID: post.id, cheered: previousCheered, cheersCount: previousCount)
            cheersError = error.friendlyMessage
        } catch {
            reconcile(postID: post.id, cheered: previousCheered, cheersCount: previousCount)
            cheersError = "Couldn't update Cheers. Please try again."
        }
    }

    private func reconcile(postID: UUID, cheered: Bool, cheersCount: Int) {
        guard let index = posts.firstIndex(where: { $0.id == postID }) else { return }
        posts[index].viewerHasCheered = cheered
        posts[index].cheersCount = cheersCount
    }

    /// `PostCommentsSheet`'s `onCommentCountChanged` callback, threaded through `FeedPostCard`.
    /// `delta` is `+1`/`-1` (a confirmed send/delete), never an absolute count — `comments.count`
    /// inside the sheet is only however many rows are loaded, not the thread total, so applying a
    /// delta to the count this state already holds (seeded from `FeedPostDTO.commentCount`, the
    /// server's real total) is what keeps drift structurally impossible: a 45-comment thread that
    /// has loaded 30 rows and gets a new comment goes 45→46 either way, never 30→31.
    /// A no-op if the post has since scrolled out of `posts` (e.g. paged away while the sheet was
    /// open) — there is nothing left to update. Clamped at 0 as a defensive floor only; a correct
    /// caller never drives it negative.
    func applyCommentCountDelta(postID: UUID, delta: Int) {
        guard let index = posts.firstIndex(where: { $0.id == postID }) else { return }
        posts[index].commentCount = max(0, posts[index].commentCount + delta)
    }

    /// Deletes a post the viewer owns. Destructive and irreversible from the user's side — the
    /// confirmation itself lives in `FeedPostCard`'s `confirmationDialog`, not here; by the time
    /// this is called the user has already confirmed. On success the post is removed from `posts`
    /// locally rather than waiting for the next full refresh, the same "adjust local state once
    /// the server has confirmed" shape as `applyCommentCountDelta`. A no-op if the post has
    /// already scrolled out of `posts` or a delete for it is already outstanding.
    func deletePost(_ post: FeedPostState) async {
        guard !deletingPostIDs.contains(post.id) else { return }
        deletingPostIDs.insert(post.id)
        defer { deletingPostIDs.remove(post.id) }
        do {
            try await deletePostRequest(post.id)
            deletedPostIDs.insert(post.id)
            posts.removeAll { $0.id == post.id }
        } catch let error as SupabaseError {
            deleteError = error.friendlyMessage
        } catch {
            deleteError = "Couldn't delete that post. Please try again."
        }
    }
}
