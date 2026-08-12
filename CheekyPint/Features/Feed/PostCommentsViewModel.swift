import Foundation
import CheekyPintCore

/// Drives `PostCommentsSheet`. Matches `FeedViewModel`'s shape: a `@MainActor @Observable` class
/// with injectable closure seams for the repository calls a test needs to control, all built
/// **inside the init body** rather than as default parameter expressions — Swift cannot
/// reference a sibling parameter (`container`) in a default-parameter expression, which is
/// exactly the mistake `FeedViewModel.swift:29`'s doc calls out as having cost a fix round in
/// Part 1.
@MainActor
@Observable
final class PostCommentsViewModel {
    /// Mirrors `add_comment`'s own clamp: `left(v_body, 280)` (`20260811000600_rpc_feed_social.sql`).
    static let bodyLimit = 280

    let postID: UUID

    private(set) var comments: [PostCommentDTO] = []
    private(set) var isLoading = false
    private(set) var isSending = false
    private(set) var loadError: SupabaseError?
    private(set) var hasMore = true

    /// The autocomplete's only source — friends only, matching `add_comment`'s server-side
    /// restriction (see this file's `suggestions(for:)`).
    private(set) var friends: [FriendDTO] = []

    /// Used to decide which rows in `PostCommentsSheet` get a swipe-to-delete. `nil` until
    /// `load()` has resolved it (real mode: `ProfileRepository.fetchMyProfile`; demo mode is
    /// intercepted there already, so no separate demo branch is needed here).
    private(set) var currentUserID: UUID?

    /// Surfaced separately from `loadError`, matching `FeedViewModel.cheersError`'s reasoning: a
    /// failed send or delete shouldn't blank an already-loaded thread into the full-screen error
    /// state — it's a transient, dismissable message instead.
    var sendError: String?

    private let pageSize: Int
    private let onCommentCountChanged: (Int) -> Void

    private let commentsRequest: (UUID, FeedCursor?, Int) async throws -> [PostCommentDTO]
    private let addCommentRequest: (UUID, String, [UUID]) async throws -> UUID
    private let deleteCommentRequest: (UUID) async throws -> Void
    private let friendsRequest: () async throws -> [FriendDTO]
    private let currentProfileRequest: () async throws -> Profile

    private static let sanitizer = ProfileTextSanitizer()
    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// Comments currently being deleted, so a second swipe on the same row while the first
    /// request is still in flight is ignored rather than firing a duplicate `delete_comment` —
    /// same reasoning as `FeedViewModel.cheersInFlight`.
    private var deletingIDs: Set<UUID> = []

    init(postID: UUID, container: AppContainer, pageSize: Int = 30,
         onCommentCountChanged: @escaping (Int) -> Void,
         comments: ((UUID, FeedCursor?, Int) async throws -> [PostCommentDTO])? = nil,
         addComment: ((UUID, String, [UUID]) async throws -> UUID)? = nil,
         deleteComment: ((UUID) async throws -> Void)? = nil,
         fetchFriends: (() async throws -> [FriendDTO])? = nil,
         currentProfile: (() async throws -> Profile)? = nil) {
        self.postID = postID
        self.pageSize = pageSize
        self.onCommentCountChanged = onCommentCountChanged
        self.commentsRequest = comments ?? { postID, cursor, limit in
            try await container.feed.comments(postID: postID, before: cursor, limit: limit)
        }
        self.addCommentRequest = addComment ?? { postID, body, mentions in
            try await container.feed.addComment(postID: postID, body: body, mentions: mentions)
        }
        self.deleteCommentRequest = deleteComment ?? { commentID in
            try await container.feed.deleteComment(commentID)
        }
        self.friendsRequest = fetchFriends ?? { try await container.friends.fetchFriends() }
        self.currentProfileRequest = currentProfile ?? { try await container.profiles.fetchMyProfile() }
    }

    // MARK: - Loading

    /// First load: the comment thread, the viewer's friends (the mention autocomplete's only
    /// source), and the viewer's own id (for swipe-to-delete). Friends/profile failures are
    /// swallowed on purpose — a friend-list hiccup shouldn't block reading or writing comments,
    /// it should just mean mentions/delete are unavailable until the next `load()`.
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        comments = []
        defer { isLoading = false }
        await fetchFirstPage()
        friends = (try? await friendsRequest()) ?? []
        currentUserID = (try? await currentProfileRequest())?.id
    }

    /// Infinite scroll, mirroring `FeedViewModel.loadMore()`: no-op while a load is already in
    /// flight or once a short page has said there is nothing more, and de-duplicates by id so a
    /// repeated boundary row (see `post_comments_page`'s own note on its keyset cursor) can't be
    /// double-counted.
    func loadMore() async {
        guard !isLoading, hasMore, let cursor = comments.last?.cursor else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await commentsRequest(postID, cursor, pageSize)
            appendDeduplicated(page)
            hasMore = page.count == pageSize
        } catch let cancellation where cancellation.isCancellation {
            // See the matching catch in `FeedViewModel.loadMore()` — the sheet being dismissed
            // mid-fetch isn't a failure worth surfacing.
        } catch let error as SupabaseError {
            loadError = error
        } catch {
            loadError = .unknown("Couldn't load more comments.")
        }
    }

    private func fetchFirstPage() async {
        do {
            let page = try await commentsRequest(postID, nil, pageSize)
            comments = page
            hasMore = page.count == pageSize
        } catch let cancellation where cancellation.isCancellation {
        } catch let error as SupabaseError {
            loadError = error
        } catch {
            loadError = .unknown("Couldn't load comments.")
        }
    }

    private func appendDeduplicated(_ newComments: [PostCommentDTO]) {
        var seenIDs = Set(comments.map(\.id))
        for comment in newComments where !seenIDs.contains(comment.id) {
            comments.append(comment)
            seenIDs.insert(comment.id)
        }
    }

    // MARK: - Sending

    /// Sanitises, then sends. `mentions` is the composer's `[UUID: displayName]` record of every
    /// suggestion the user picked; `MentionScanner.stillPresent` — not a re-parse of `cleanBody`
    /// — decides which of those ids are still actually in the text (see that type's doc for why
    /// re-parsing free text for `@Name` tokens is the wrong approach once names can contain
    /// spaces). A friend who is dropped server-side for being unable to see the post (see
    /// `add_comment`'s own note) still returns success here — that silent drop is a property of
    /// the server's response, invisible to the client either way.
    ///
    /// Returns whether the send succeeded, purely so `PostCommentsSheet` knows whether to clear
    /// its draft text — the view model's own state (`comments`, `sendError`) is the source of
    /// truth for everything else.
    @discardableResult
    func send(rawBody: String, mentions: [UUID: String]) async -> Bool {
        guard !isSending else { return false }
        let cleanBody = Self.sanitizer.sanitize(rawBody, allowNewlines: true, maxLength: Self.bodyLimit)
        guard !cleanBody.isEmpty else { return false }

        isSending = true
        sendError = nil
        defer { isSending = false }

        let mentionIDs = MentionScanner.stillPresent(mentions: mentions, in: cleanBody)
        do {
            let commentID = try await addCommentRequest(postID, cleanBody, mentionIDs)
            // `add_comment` only returns the new id (see `RPCContracts.CreatedCommentDTO`), not a
            // full row, so the rest of this comment's display fields are filled in from the
            // viewer's own profile rather than a second round trip to re-fetch the thread.
            let author = try? await currentProfileRequest()
            if let author { currentUserID = author.id }
            let newComment = PostCommentDTO(
                commentId: commentID,
                authorId: author?.id ?? currentUserID ?? UUID(),
                displayName: author?.displayName ?? "You",
                avatarPath: author?.avatarPath,
                body: cleanBody,
                createdAtRaw: Self.timestampStyle.format(Date()),
                mentionedUserIds: mentionIDs)
            comments.append(newComment)
            onCommentCountChanged(comments.count)
            return true
        } catch let error as SupabaseError {
            sendError = error.friendlyMessage
            return false
        } catch {
            sendError = "Couldn't post that comment. Please try again."
            return false
        }
    }

    // MARK: - Deleting

    func delete(_ comment: PostCommentDTO) async {
        guard !deletingIDs.contains(comment.id) else { return }
        deletingIDs.insert(comment.id)
        defer { deletingIDs.remove(comment.id) }
        do {
            try await deleteCommentRequest(comment.id)
            comments.removeAll { $0.id == comment.id }
            onCommentCountChanged(comments.count)
        } catch let error as SupabaseError {
            sendError = error.friendlyMessage
        } catch {
            sendError = "Couldn't delete that comment. Please try again."
        }
    }

    // MARK: - Mention autocomplete

    /// Friends whose display name contains `token`, case-insensitively. Friends are the *only*
    /// source (never a user-search RPC — none exists, see the interface inventory), matching
    /// `add_comment`'s own friends-only restriction: offering anything else here would let the
    /// user pick a mention the server is guaranteed to reject, failing the whole comment.
    /// An empty token (a bare `@` just typed) matches every friend.
    func suggestions(for token: String) -> [FriendDTO] {
        guard !token.isEmpty else { return friends }
        return friends.filter { $0.displayName.localizedCaseInsensitiveContains(token) }
    }
}

private extension Error {
    /// True for both `CancellationError` and `URLError.cancelled` — see the identical extension
    /// (and its doc) in `FeedViewModel.swift`; duplicated per-file rather than shared, matching
    /// that file's own `private` (file-scoped) visibility.
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if let urlError = self as? URLError, urlError.code == .cancelled { return true }
        return false
    }
}
