import SwiftUI
import CheekyPintCore

/// The comment thread for one post, with `@mention` autocomplete. Opened from `FeedPostCard`'s
/// comment button.
///
/// **Mentions are friends-only, enforced server-side** (`add_comment` raises `'Can only mention
/// friends'` and fails the *entire* comment if any mentioned id isn't an accepted friend) — so
/// the autocomplete's only source is `PostCommentsViewModel.friends`
/// (`FriendsRepository.fetchFriends()`), never a general user search (none exists). A friend who
/// cannot see this particular post is silently dropped by the server rather than rejected, so
/// this UI never claims a mention was definitely delivered — it only shows what was typed.
///
/// **Never re-parses `@names` out of the final text.** Display names contain spaces
/// ("Barnaby Pemberton-Smythe"), so a mention has no unambiguous end once it's back in free text.
/// Instead, picking a suggestion records `[UUID: displayName]` in `mentions`, and
/// `MentionScanner.stillPresent` (called by the view model on send) keeps only the ids whose
/// `@displayName` is still literally present — so deleting the visible mention text is enough to
/// drop it, with no re-parse.
struct PostCommentsSheet: View {
    let postID: UUID
    let onCommentCountChanged: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.container) private var container

    @State private var model: PostCommentsViewModel?
    @State private var commentBody = ""
    /// Every friend the user has picked from the autocomplete so far in this draft, keyed by
    /// their id. Read by `send()` via `MentionScanner.stillPresent` — see this type's doc.
    @State private var mentions: [UUID: String] = [:]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                commentsList
                if let token = activeToken, !suggestions.isEmpty {
                    Divider()
                    suggestionList
                }
                Divider()
                composer
            }
            .pubBackground()
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("comments-close")
                        .accessibilityLabel("Close")
                }
            }
        }
        .presentationDetents([.large])
        .task {
            guard model == nil else { return }
            let vm = PostCommentsViewModel(postID: postID, container: container,
                                           onCommentCountChanged: onCommentCountChanged)
            model = vm
            await vm.load()
        }
    }

    // MARK: - Comments list

    @ViewBuilder
    private var commentsList: some View {
        if let model {
            if model.isLoading && model.comments.isEmpty {
                ProgressView().tint(Theme.Palette.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.loadError, model.comments.isEmpty {
                StatusView(systemImage: "wifi.slash", title: "Couldn't load comments",
                           message: error.friendlyMessage, actionTitle: "Retry") {
                    Task { await model.load() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.comments.isEmpty {
                StatusView(systemImage: "bubble.right", title: "No comments yet",
                           message: "Be the first to say something.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if let sendError = model.sendError {
                        Text(sendError)
                            .foregroundStyle(Theme.Palette.warning)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    ForEach(model.comments) { comment in
                        commentRow(comment, model: model)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .onAppear {
                                guard comment.id == model.comments.last?.id else { return }
                                Task { await model.loadMore() }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        } else {
            ProgressView().tint(Theme.Palette.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Built once and reused by every row, matching `FeedPostCard`'s identical formatters (see
    /// that type's doc for why: `RelativeDateTimeFormatter` is expensive to construct and must
    /// never be created inside `body`).
    private static let relativeTimeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static let relativeTimeAccessibilityFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private func commentRow(_ comment: PostCommentDTO, model: PostCommentsViewModel) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            RemoteAvatar(url: container.avatarURL(for: comment.avatarPath), name: comment.displayName, size: 32)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(comment.displayName)
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    if let createdAt = comment.createdAt {
                        Text(Self.relativeTimeFormatter.localizedString(for: createdAt, relativeTo: Date()))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .accessibilityLabel(Self.relativeTimeAccessibilityFormatter.localizedString(
                                for: createdAt, relativeTo: Date()))
                    }
                }
                Text(Self.highlightedBody(comment.body, mentionNames: model.friends.map(\.displayName)))
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
        }
        .accessibilityElement(children: .combine)
        .swipeActions {
            if let currentUserID = model.currentUserID, comment.authorId == currentUserID {
                Button(role: .destructive) {
                    Task { await model.delete(comment) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .accessibilityIdentifier("comment-delete-\(comment.id)")
                .accessibilityLabel("Delete comment")
            }
        }
    }

    /// Highlights every literal occurrence of `@<name>` (for each candidate in `mentionNames`) in
    /// `Theme.Palette.forest`. Candidates come from the viewer's own friends list — the only
    /// display names available client-side, since `PostCommentDTO.mentionedUserIds` carries ids,
    /// not names (mentions are recorded at write time, not re-derived from text on read; see
    /// `comment_mentions`' own migration note). A mention of someone outside the viewer's friends
    /// list (e.g. a mutual friend of the post's author the viewer hasn't added) simply isn't
    /// highlighted — a cosmetic gap, not a data-correctness one, since the literal `@Name` text
    /// the author typed is still shown either way.
    ///
    /// Marks matches with a per-character boolean mask rather than searching token-by-token into
    /// the final `AttributedString` — a longer name that is itself a superset of a shorter one
    /// ("Barnaby Pemberton-Smythe" containing "Barnaby") then highlights correctly regardless of
    /// which order the two names are checked in, since the mask is a straightforward OR.
    static func highlightedBody(_ body: String, mentionNames: [String]) -> AttributedString {
        let characters = Array(body)
        guard !characters.isEmpty else { return AttributedString() }
        var highlighted = [Bool](repeating: false, count: characters.count)
        for name in mentionNames where !name.isEmpty {
            let token = Array("@\(name)")
            guard token.count <= characters.count else { continue }
            var start = 0
            while start + token.count <= characters.count {
                if Array(characters[start..<(start + token.count)]) == token {
                    for index in start..<(start + token.count) { highlighted[index] = true }
                    start += token.count
                } else {
                    start += 1
                }
            }
        }

        var result = AttributedString()
        var index = 0
        while index < characters.count {
            let isHighlighted = highlighted[index]
            var end = index
            while end < characters.count, highlighted[end] == isHighlighted { end += 1 }
            var run = AttributedString(String(characters[index..<end]))
            if isHighlighted { run.foregroundColor = Theme.Palette.forest }
            result += run
            index = end
        }
        return result
    }

    // MARK: - Mention autocomplete

    /// The `@token` under the cursor, if any. The composer only supports typing/autocomplete at
    /// the end of the draft (no mid-text cursor tracking), so the cursor is always the end of
    /// `commentBody` — a deliberate simplification matching how most mention composers work.
    private var activeToken: String? {
        MentionScanner.activeToken(in: commentBody, upTo: commentBody.count)
    }

    private var suggestions: [FriendDTO] {
        guard let model, let token = activeToken else { return [] }
        return model.suggestions(for: token)
    }

    private var suggestionList: some View {
        List {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, friend in
                Button {
                    select(friend)
                } label: {
                    HStack(spacing: Theme.Spacing.sm) {
                        RemoteAvatar(url: container.avatarURL(for: friend.avatarPath), name: friend.displayName, size: 28)
                        Text(friend.displayName).foregroundStyle(Theme.Palette.textPrimary)
                        Spacer(minLength: 0)
                    }
                }
                .accessibilityIdentifier("mention-suggestion-\(index)")
                .accessibilityLabel("Mention \(friend.displayName)")
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(maxHeight: 180)
        .background(Theme.Palette.backgroundSecondary)
    }

    /// Replaces the active `@token` (always at the end of `commentBody` — see `activeToken`'s
    /// doc) with `@<displayName> ` and records the pick in `mentions`, so `send()` can later ask
    /// `MentionScanner.stillPresent` whether it's still actually in the text.
    private func select(_ friend: FriendDTO) {
        guard activeToken != nil, let atIndex = commentBody.lastIndex(of: "@") else { return }
        commentBody.replaceSubrange(atIndex..<commentBody.endIndex, with: "@\(friend.displayName) ")
        mentions[friend.userId] = friend.displayName
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: Theme.Spacing.sm) {
            TextField("Add a comment…", text: $commentBody, axis: .vertical)
                .lineLimit(1...4)
                .accessibilityIdentifier("comment-body-field")
                .accessibilityLabel("Comment")
            Button {
                Task { await send() }
            } label: {
                Image(systemName: "paperplane.fill")
            }
            .disabled(!canSend)
            .frame(minWidth: Theme.minTapTarget, minHeight: Theme.minTapTarget)
            .accessibilityIdentifier("comment-send")
            .accessibilityLabel("Send comment")
        }
        .padding(Theme.Spacing.sm)
        .background(Theme.Palette.backgroundSecondary)
    }

    private var canSend: Bool {
        guard let model else { return false }
        return !model.isSending && !commentBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() async {
        guard let model, canSend else { return }
        let succeeded = await model.send(rawBody: commentBody, mentions: mentions)
        if succeeded {
            commentBody = ""
            mentions = [:]
        }
    }
}
