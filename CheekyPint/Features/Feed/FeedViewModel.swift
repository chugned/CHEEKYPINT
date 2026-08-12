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
    /// already-loaded feed into the full-screen error state — it's a transient alert instead,
    /// the same pattern `LeaderboardView` uses for a failed Nudge.
    var cheersError: String?

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

    init(container: AppContainer, pageSize: Int = 20,
         toggleCheers: ((UUID) async throws -> ToggleCheersDTO)? = nil,
         page: ((FeedCursor?, Int) async throws -> [FeedPostDTO])? = nil) {
        self.container = container
        self.pageSize = pageSize
        self.toggleCheersRequest = toggleCheers ?? { try await container.feed.toggleCheers(postID: $0) }
        self.pageRequest = page ?? { cursor, limit in try await container.feed.page(before: cursor, limit: limit) }
    }

    /// First load. Clears any existing posts up front so a retry after an error doesn't show
    /// stale content next to the error state. Guarded by the same `isLoading` flag as `refresh()`
    /// and `loadMore()` (see the note there) so this can't race either of them.
    func load() async {
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
    func reload() async {
        await refresh()
    }

    private func fetchFirstPage() async {
        do {
            let page = try await pageRequest(nil, pageSize)
            posts = page.map(FeedPostState.init)
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
        guard !isLoading, hasMore, let cursor = posts.last?.cursor else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await pageRequest(cursor, pageSize)
            appendDeduplicated(page.map(FeedPostState.init))
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

    /// Appends `newPosts`, skipping any id already present — either already in `posts` (a repeat
    /// across pages) or repeated within `newPosts` itself (a repeat within one page).
    private func appendDeduplicated(_ newPosts: [FeedPostState]) {
        var seenIDs = Set(posts.map(\.id))
        for post in newPosts where !seenIDs.contains(post.id) {
            posts.append(post)
            seenIDs.insert(post.id)
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
}

private extension Error {
    /// True for both `CancellationError` (thrown at a cooperative-cancellation checkpoint) and
    /// `URLError.cancelled` (what `URLSession`'s async APIs throw when the owning `Task` is
    /// cancelled mid-request) — the two shapes a cancelled feed fetch actually arrives in.
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if let urlError = self as? URLError, urlError.code == .cancelled { return true }
        return false
    }
}
