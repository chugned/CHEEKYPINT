import SwiftUI
import CheekyPintCore

/// One post in the friends-only feed: author header, optional place label, optional photo,
/// optional body text, and a footer with the Cheers toggle and the (display-only, for now)
/// comment count.
struct FeedPostCard: View {
    let post: FeedPostState
    let avatarURL: URL?
    let imageURL: URL?
    let onToggleCheers: () -> Void
    /// A **delta** (`+1`/`-1`), reported by `PostCommentsSheet` whenever a comment is confirmed
    /// added or deleted — never an absolute count, since the sheet only knows how many comments
    /// it has *loaded*, not the thread total. Threaded through to
    /// `FeedViewModel.applyCommentCountDelta(postID:delta:)` by whoever constructs this card, so
    /// it adjusts the authoritative count this card already has rather than replacing it.
    let onCommentCountChanged: (Int) -> Void
    /// Called once the viewer has confirmed the `confirmationDialog` in `postMenu` below — by the
    /// time this fires, the destructive action is already confirmed. Wired by whoever constructs
    /// this card to `FeedViewModel.deletePost(_:)`, matching `onToggleCheers`'s shape.
    let onDeletePost: () -> Void

    @Environment(SessionController.self) private var session

    @State private var showingComments = false
    @State private var showingReport = false
    @State private var showingDeleteConfirmation = false

    /// Same route `MyQRView` already uses for "the signed-in user's own id"
    /// (`session.currentProfile?.id`) — not a new lookup invented for this card.
    private var isOwnPost: Bool {
        session.currentProfile?.id == post.post.authorId
    }

    /// Built once and reused by every row — `RelativeDateTimeFormatter` is expensive to
    /// construct, so it must never be created inside `body`, which SwiftUI re-evaluates often.
    /// Abbreviated for the visible caption ("30 min. ago" rather than `Text(_:style:.relative)`'s
    /// "30 min, 7 secs"/"1 hr, 30 min" compound form).
    private static let relativeTimeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// Same formatter, spelled out in full, for VoiceOver — an abbreviated unit read aloud
    /// ("30 min ago") is worse than the full word ("30 minutes ago"), so the accessibility label
    /// uses this one instead of the visible text.
    private static let relativeTimeAccessibilityFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            header
            placeLabelRow
            photo
            bodyText
            footer
        }
        .coasterCard()
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            RemoteAvatar(url: avatarURL, name: post.post.displayName, size: 40)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(post.post.displayName)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Palette.textPrimary)
                if let createdAt = post.post.createdAt {
                    Text(Self.relativeTimeFormatter.localizedString(for: createdAt, relativeTo: Date()))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .accessibilityLabel(Self.relativeTimeAccessibilityFormatter.localizedString(
                            for: createdAt, relativeTo: Date()))
                }
            }
            Spacer(minLength: 0)
            postMenu
        }
    }

    /// The overflow menu: Report is always offered; Delete is offered only for the viewer's own
    /// posts, and is never the menu's default/prominent action — it sits second, behind Report,
    /// and only takes effect after the `confirmationDialog` below is explicitly confirmed.
    /// Deleting a post is destructive and irreversible from the user's side, so that dialog's
    /// copy says so plainly rather than implying anything softer.
    private var postMenu: some View {
        Menu {
            Button {
                showingReport = true
            } label: {
                Label("Report", systemImage: "flag")
            }
            .accessibilityIdentifier("post-report-\(post.id)")
            .accessibilityLabel("Report this post")

            if isOwnPost {
                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .accessibilityIdentifier("post-delete-\(post.id)")
                .accessibilityLabel("Delete this post")
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(minWidth: Theme.minTapTarget, minHeight: Theme.minTapTarget)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("post-menu-\(post.id)")
        .accessibilityLabel("Post options")
        .confirmationDialog(
            "Delete this post?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { onDeletePost() }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Plain, unambiguous: this is the one piece of copy the brief requires — deleting a
            // post cannot be undone from the user's side, and the dialog must say so outright.
            Text("This can't be undone.")
        }
        .sheet(isPresented: $showingReport) {
            ReportContentView(target: .post(id: post.id, hasPhoto: post.post.imagePath != nil))
        }
    }

    @ViewBuilder
    private var placeLabelRow: some View {
        if let placeLabel = post.post.placeLabel {
            HStack(spacing: Theme.Spacing.xxs) {
                Image(systemName: "mappin.and.ellipse")
                    .accessibilityHidden(true)
                Text(placeLabel)
                    .font(Theme.Typography.caption)
            }
            .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    /// Fixed tile height for the photo, independent of the source image's aspect ratio. This is
    /// the load-bearing constraint: `.resizable().scaledToFill()` sizes itself from whatever it's
    /// proposed, and with only `.frame(maxWidth: .infinity)` above it — a "grow to fill" request,
    /// not a cap — SwiftUI's ideal-size pass for the enclosing `VStack` had nothing to derive a
    /// width from, so it fell back to the underlying `UIImage`'s native pixel size (1200×900 for
    /// the demo photo) as the image's ideal width. The `VStack` adopted that as the card's width,
    /// which is what pushed the whole card past the screen edge. Pinning `minHeight == maxHeight`
    /// here means every layout pass — the ideal-size query included — always has a concrete
    /// height to derive width from via the image's own aspect ratio, so the derived width is
    /// always a small, sane multiple of this constant, never the source pixel size. Fixing the
    /// height also gives every card in the feed the same photo tile size regardless of the source
    /// image's orientation.
    private static let photoHeight: CGFloat = 200

    @ViewBuilder
    private var photo: some View {
        if let imageURL {
            RemoteImage(url: imageURL) { phase in
                ZStack {
                    Theme.Palette.backgroundPrimary
                    switch phase {
                    case .loading:
                        ProgressView().tint(Theme.Palette.accent)
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        photoUnavailablePlaceholder
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: Self.photoHeight, maxHeight: Self.photoHeight)
            // `.clipShape` alone clips rendering to the rounded-rect bounds established by the
            // frame above; a preceding plain `.clipped()` (which clips to the same rectangular
            // bounds) has no additional effect once `.clipShape` is present, so it's dropped.
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        }
    }

    /// The failure phase, styled to read as "this photo just isn't available right now" rather
    /// than as a broken image the viewer should do something about — muted icon and caption,
    /// both `Theme.Palette.textSecondary`, no warning colour. Kept (never hidden): losing the
    /// photo area entirely would also lose the place it holds in the card's layout.
    private var photoUnavailablePlaceholder: some View {
        VStack(spacing: Theme.Spacing.xxs) {
            Image(systemName: "photo")
                .font(.system(size: 28))
            Text("Photo unavailable")
                .font(Theme.Typography.caption)
        }
        .foregroundStyle(Theme.Palette.textSecondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Photo could not be loaded")
    }

    @ViewBuilder
    private var bodyText: some View {
        if let body = post.post.body, !body.isEmpty {
            Text(body)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textPrimary)
        }
    }

    private var footer: some View {
        HStack {
            CheersButton(cheered: post.viewerHasCheered, count: post.cheersCount, action: onToggleCheers)
            Spacer(minLength: 0)
            Button {
                showingComments = true
            } label: {
                Label("\(post.commentCount)", systemImage: "bubble.right")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .frame(minHeight: Theme.minTapTarget)
            .contentShape(Rectangle())
            .accessibilityIdentifier("post-comments-button")
            .accessibilityLabel(commentCountAccessibilityLabel)
            .accessibilityHint("Opens the comments for this post")
        }
        .sheet(isPresented: $showingComments) {
            PostCommentsSheet(postID: post.id, onCommentCountChanged: onCommentCountChanged)
        }
    }

    private var commentCountAccessibilityLabel: String {
        post.commentCount == 1 ? "1 comment" : "\(post.commentCount) comments"
    }
}

/// The Cheers control. The label always carries the current count (the UI test observes it
/// changing on tap), and honours Reduce Motion on its scale effect exactly as `PintButtonStyle`
/// does. There is no dedicated "clinking beer mugs" glyph in SF Symbols (checked the iOS 26.5
/// symbol catalog directly — only bare `mug`/`mug.fill` exist), so this reuses `mug.fill`: the
/// same pint glyph the Logger tab uses for logging a beer, repurposed here for cheering someone
/// else's. The two are different affordances in different navigation contexts, and no other
/// symbol in the catalog reads as "cheers" more clearly.
private struct CheersButton: View {
    let cheered: Bool
    let count: Int
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Label("\(count) Cheers", systemImage: "mug.fill")
                .font(Theme.Typography.callout.weight(.semibold))
        }
        .foregroundStyle(cheered ? Theme.Palette.accent : Theme.Palette.textSecondary)
        .scaleEffect(reduceMotion ? 1 : (cheered ? 1.08 : 1))
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.6), value: cheered)
        .frame(minHeight: Theme.minTapTarget)
        .contentShape(Rectangle())
        .accessibilityIdentifier("cheers-toggle")
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(cheered ? "Removes your cheer from this post" : "Cheers this post")
    }

    private var accessibilityLabel: String {
        let countPhrase = count == 1 ? "1 cheer" : "\(count) cheers"
        return cheered ? "Cheered, \(countPhrase)" : countPhrase
    }
}
