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
    /// Mirrors `add_comment`'s `left(v_body, 280)` clamp
    /// (`20260811000600_rpc_feed_social.sql`), re-exported from the view model that actually sends
    /// so the counter, the Send gate and the clamp can never disagree about the number.
    static let bodyLimit = PostCommentsViewModel.bodyLimit

    /// Shared with `ComposePostSheet`'s reasoning: the counter and the gate must both measure what
    /// will be **stored**, in the server's unit (code points), not raw grapheme clusters — see
    /// `ProfileTextSanitizer.sanitizedLength`.
    private static let sanitizer = ProfileTextSanitizer()

    /// How long this draft will be once stored. `static` so the Send gate below is directly
    /// testable without a view instance, matching `ComposePostSheet.bodyLength(of:)`.
    static func bodyLength(of body: String) -> Int {
        sanitizer.sanitizedLength(body, allowNewlines: true)
    }

    /// Whether Send should be enabled, ignoring the in-flight check the view adds on top.
    ///
    /// The over-limit half is the point of this function existing. Without it a 350-character
    /// comment left Send enabled, `PostCommentsViewModel.send` clamped it to 280, returned `true`,
    /// and the composer cleared the draft — 70 characters gone with nothing on screen to say so.
    /// `ComposePostSheet.canSubmit` has always deliberately refused to do that for its own 500
    /// limit; this is the same rule for the comment composer's 280.
    static func canSend(body: String) -> Bool {
        let length = bodyLength(of: body)
        return length > 0 && length <= bodyLimit
    }

    let postID: UUID
    /// Forwarded straight to `PostCommentsViewModel.init` — see that type's doc: this is a
    /// **delta** (`+1`/`-1`), not an absolute count.
    let onCommentCountChanged: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.container) private var container

    @State private var model: PostCommentsViewModel?
    @State private var commentBody = ""
    /// Every friend the user has picked from the autocomplete so far in this draft, keyed by
    /// their id. Read by `send()` via `MentionScanner.stillPresent` — see this type's doc.
    @State private var mentions: [UUID: String] = [:]
    /// The comment currently being reported, if any — drives the `.sheet(item:)` below.
    /// `PostCommentDTO` is already `Identifiable`, so this doubles as both "is a report sheet
    /// showing" and "which comment it's for" with no extra Bool to keep in sync.
    @State private var reportingComment: PostCommentDTO?
    /// See `AccessibilityAnnouncer`'s doc — speaks `model?.sendError` for VoiceOver, deduped so a
    /// retry that hits the identical error doesn't nag.
    @State private var announcer = AccessibilityAnnouncer()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Shown here — outside `commentsList`'s own branching — so a failed send/delete
                // is visible regardless of whether the thread is empty, loading, or populated.
                // The old placement (a row inside the populated-thread `List`) meant a failed
                // send on a brand-new post (zero comments — the common case right after
                // composing) rendered the "No comments yet" empty state instead, and the error
                // was never shown at all.
                if let sendError = model?.sendError {
                    Text(sendError)
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Palette.warning)
                        // Found by screenshot at accessibility XXL with the keyboard up, not by
                        // code review: `commentsList` below is a flexible sibling in this
                        // `VStack`, and with the keyboard eating half the screen there wasn't
                        // enough height left to propose this `Text` its full 3-line ideal — it
                        // rendered "You're offline. We'll try again when yo…", silently losing
                        // the rest of the sentence with no visual sign anything was cut. Locking
                        // this view to its own ideal height, regardless of what the parent
                        // proposes, is what actually fixes it (a `Text` with no explicit
                        // `.lineLimit` still truncates with an ellipsis once its *proposed*
                        // height is smaller than what full wrapping needs).
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.top, Theme.Spacing.sm)
                        .accessibilityIdentifier("comments-send-error")
                }
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
        .sheet(item: $reportingComment) { comment in
            ReportContentView(target: .comment(id: comment.id))
        }
        .presentationDetents([.large])
        // See `AccessibilityAnnouncer`'s doc — announces the send/delete error for VoiceOver on
        // genuine change only.
        .onChange(of: model?.sendError) { _, new in announcer.announce(new) }
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

    private func commentRow(_ comment: PostCommentDTO, model: PostCommentsViewModel) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            RemoteAvatar(url: container.avatarURL(for: comment.avatarPath), name: comment.displayName, size: 32)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                // Stacked vertically, matching `FeedPostCard.header`'s identical name+time pair —
                // not a bespoke fix. Side-by-side in an `HStack` at accessibility XXL, "Barnaby"
                // had too little width left next to "20 min ago" and hyphenated mid-word into
                // "Barn-"/"aby" across two lines; stacking gives each its own full-width line.
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(comment.displayName)
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    if let createdAt = comment.createdAt {
                        Text(RelativeTime.caption.localizedString(for: createdAt, relativeTo: Date()))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .accessibilityLabel(RelativeTime.accessibility.localizedString(
                                for: createdAt, relativeTo: Date()))
                    }
                }
                Text(Self.highlightedBody(comment.body, mentionedUserIDs: comment.mentionedUserIds,
                                          friends: model.friends))
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            // Grouped separately from the row's trailing `commentMenu` below: `.combine` merges
            // every child into one VoiceOver element, which would swallow the menu button's own
            // tap action into the read-only text summary if it were included in this group.
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            commentMenu(comment)
        }
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

    /// The per-comment overflow menu — Report only. Swipe-to-delete for the viewer's own comments
    /// already exists above; this must not add a second delete affordance.
    private func commentMenu(_ comment: PostCommentDTO) -> some View {
        Menu {
            Button {
                reportingComment = comment
            } label: {
                Label("Report", systemImage: "flag")
            }
            .accessibilityIdentifier("comment-report-\(comment.id)")
            .accessibilityLabel("Report this comment")
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(minWidth: Theme.minTapTarget, minHeight: Theme.minTapTarget)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("comment-menu-\(comment.id)")
        .accessibilityLabel("Comment options")
    }

    /// Highlights every literal occurrence of `@<name>` in `Theme.Palette.forest`, but **only**
    /// for names resolved from `mentionedUserIDs`, never from an arbitrary text match. This is
    /// deliberate, not a convenience: the brief is explicit that the UI must never imply a
    /// mention was delivered when it wasn't. `mentionedUserIds` is exactly what the server
    /// recorded in `comment_mentions` at write time (see that table's own migration note); typing
    /// `cheers @Ceri` by hand without ever using autocomplete sends **no** mention at all
    /// (`add_comment` only records ids passed in `p_mentions`), so that literal text must render
    /// as plain text, not as a false promise of a real tag.
    ///
    /// Names are resolved from the viewer's own friends list — the only display names available
    /// client-side, since `mentionedUserIds` carries ids, not names. A mention of someone outside
    /// the viewer's friends list (e.g. a mutual friend of the post's author the viewer hasn't
    /// added) simply isn't highlighted — a cosmetic gap, not a data-correctness one, since the
    /// literal `@Name` text the author typed is still shown either way.
    static func highlightedBody(_ body: String, mentionedUserIDs: [UUID], friends: [FriendDTO]) -> AttributedString {
        let friendNamesByID = Dictionary(uniqueKeysWithValues: friends.map { ($0.userId, $0.displayName) })
        let mentionNames = mentionedUserIDs.compactMap { friendNamesByID[$0] }
        return highlightedBody(body, mentionNames: mentionNames)
    }

    /// Marks matches with a per-character boolean mask rather than searching token-by-token into
    /// the final `AttributedString` — a longer name that is itself a superset of a shorter one
    /// ("Barnaby Pemberton-Smythe" containing "Barnaby") then highlights correctly regardless of
    /// which order the two names are checked in, since the mask is a straightforward OR. Split
    /// out from the public overload above purely so this pure masking logic is directly testable
    /// without needing to fabricate `FriendDTO`s.
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
                        Text(friend.displayName)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.textPrimary)
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

    private func select(_ friend: FriendDTO) {
        guard activeToken != nil else { return }
        let result = Self.applyingMentionSelection(friend, to: commentBody, mentions: mentions)
        commentBody = result.text
        mentions = result.mentions
    }

    /// The pure core of `select(_:)` — replaces the active `@token` (always at the end of `text`,
    /// per `activeToken`'s doc) with `@<friend.displayName> ` and records the pick in `mentions`.
    ///
    /// Also **prunes** any previously-recorded mention whose `@name` lived entirely inside the
    /// token region being overwritten. Without this, extending an already-picked mention (pick
    /// "Ceri", giving `@Ceri `, then picking a second suggestion "Ceri Ann" that the still-active
    /// "Ceri " token also matches) leaves the stale `ceriID` behind in `mentions` alongside the
    /// new `ceriAnnID` — and since the final text `"@Ceri Ann "` genuinely contains `"@Ceri"` at a
    /// valid word boundary (followed by a space), `MentionScanner.stillPresent` would keep BOTH
    /// ids at send time, silently mentioning a second person nobody intended to tag. Pruning is
    /// scoped to the overwritten region only: it checks survival against the text with that
    /// region removed, so an earlier, unrelated mention elsewhere in the draft is untouched.
    static func applyingMentionSelection(
        _ friend: FriendDTO, to text: String, mentions: [UUID: String]
    ) -> (text: String, mentions: [UUID: String]) {
        guard let atIndex = text.lastIndex(of: "@") else { return (text, mentions) }
        let textBeforeToken = String(text[text.startIndex..<atIndex])
        let survivingIDs = Set(MentionScanner.stillPresent(mentions: mentions, in: textBeforeToken))
        var newMentions = mentions.filter { survivingIDs.contains($0.key) }
        newMentions[friend.userId] = friend.displayName
        let newText = textBeforeToken + "@\(friend.displayName) "
        return (newText, newMentions)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .trailing, spacing: Theme.Spacing.xxs) {
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
            // Always visible, matching `ComposePostSheet`'s counter rather than appearing only
            // once the draft is nearly full: a counter that shows up late is a counter the user
            // discovers *after* writing past the limit, which is when it is least useful.
            // `verbatim:` for the same reason as `ComposePostSheet`'s counter — see there.
            Text(verbatim: "\(bodyLength)/\(Self.bodyLimit)")
                .font(Theme.Typography.caption)
                .foregroundStyle(isOverLimit ? Theme.Palette.warning : Theme.Palette.textSecondary)
                .accessibilityIdentifier("comment-body-counter")
                .accessibilityLabel("\(bodyLength) of \(Self.bodyLimit) characters used")
        }
        .padding(Theme.Spacing.sm)
        .background(Theme.Palette.backgroundSecondary)
    }

    /// Both read through `Self.bodyLength` so what the counter shows and what Send gates on are
    /// the same number, measured the way the server will measure it.
    private var bodyLength: Int { Self.bodyLength(of: commentBody) }

    private var isOverLimit: Bool { bodyLength > Self.bodyLimit }

    private var canSend: Bool {
        guard let model else { return false }
        return !model.isSending && Self.canSend(body: commentBody)
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
