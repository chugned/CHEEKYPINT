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

    init(_ post: FeedPostDTO) {
        self.post = post
        self.viewerHasCheered = post.viewerHasCheered
        self.cheersCount = post.cheersCount
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

    init(container: AppContainer, pageSize: Int = 20) {
        self.container = container
        self.pageSize = pageSize
    }

    /// First load. Clears any existing posts up front so a retry after an error doesn't show
    /// stale content next to the error state.
    func load() async {
        isLoading = true
        loadError = nil
        posts = []
        defer { isLoading = false }
        await fetchFirstPage()
    }

    /// Pull-to-refresh. Same first page as `load()`, but posts are only replaced once the new
    /// page arrives, so the list doesn't flash empty while it's in flight.
    func refresh() async {
        loadError = nil
        await fetchFirstPage()
    }

    private func fetchFirstPage() async {
        do {
            let page = try await container.feed.page(before: nil, limit: pageSize)
            posts = page.map(FeedPostState.init)
            hasMore = page.count == pageSize
        } catch let error as SupabaseError {
            loadError = error
        } catch {
            loadError = .unknown("Couldn't load the feed.")
        }
    }

    /// Infinite scroll. No-op while a load is already in flight or once a short page has said
    /// there is nothing more.
    func loadMore() async {
        guard !isLoading, hasMore, let cursor = posts.last?.cursor else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await container.feed.page(before: cursor, limit: pageSize)
            posts.append(contentsOf: page.map(FeedPostState.init))
            hasMore = page.count == pageSize
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
    func toggleCheers(_ post: FeedPostState) async {
        guard let index = posts.firstIndex(where: { $0.id == post.id }) else { return }
        let previousCheered = posts[index].viewerHasCheered
        let previousCount = posts[index].cheersCount
        posts[index].viewerHasCheered.toggle()
        posts[index].cheersCount = max(0, previousCount + (posts[index].viewerHasCheered ? 1 : -1))

        do {
            let result = try await container.feed.toggleCheers(postID: post.id)
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
}
