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

    /// Every modal this card can put on screen, as **one** value on **one** `@State`, presented
    /// from **one** place — the card's root, below — rather than three booleans driving three
    /// presentation modifiers attached to three different sibling subviews of the same `List` row
    /// (the header's Report sheet, the photo's full-screen cover, the footer's Comments sheet),
    /// which is the shape this card shipped with. Scattering presentations across a recycled
    /// row's subviews is a known way to get the wrong modal, and this row has now produced three
    /// separate mis-routing defects (`docs/STATE_AUDIT.md` §4, §5). One enum also makes "comments
    /// and the photo viewer are both open" unrepresentable rather than merely unlikely, which is
    /// the exact shape of the reported symptom. Same remedy `FeedView` already applies to its own
    /// alerts via `FeedAlert`.
    private enum CardPresentation: String, Identifiable {
        case photo
        case comments
        case report

        var id: String { rawValue }
        /// The photo viewer is a `fullScreenCover`; the other two are sheets. Different
        /// presentation styles, still one source of truth — see `body`.
        var isCover: Bool { self == .photo }
    }

    @State private var presentation: CardPresentation?
    /// Not part of `CardPresentation`: a `confirmationDialog` is an alert-family presentation on a
    /// different channel from sheets/covers, and it is driven from inside `postMenu`'s `Menu`
    /// rather than by a control in the row — the one presentation on this card that has never
    /// mis-routed (`docs/STATE_AUDIT.md` §1/§4 both record the `Menu`/`confirmationDialog` path
    /// behaving correctly throughout). It is hoisted to the card root with the rest all the same,
    /// so "where does this card present things from" has exactly one answer.
    @State private var showingDeleteConfirmation = false

    /// Same route `MyQRView` already uses for "the signed-in user's own id"
    /// (`session.currentProfile?.id`) — not a new lookup invented for this card.
    private var isOwnPost: Bool {
        session.currentProfile?.id == post.post.authorId
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            header
            placeLabelRow
            photo
            bodyText
            footer
        }
        .coasterCard()
        // All four presentations, on the row's root, in one place. `item:` rather than
        // `isPresented:` so the presented content is derived from the same value that decided to
        // present it — there is no second piece of state for it to disagree with.
        .sheet(item: sheetPresentation) { presented in
            switch presented {
            case .comments:
                PostCommentsSheet(postID: post.id, onCommentCountChanged: onCommentCountChanged)
            case .report:
                ReportContentView(target: .post(id: post.id, hasPhoto: post.post.imagePath != nil))
            case .photo:
                // Unreachable: `sheetPresentation` filters `.photo` out. `CardPresentation` is
                // deliberately not split into two enums — one value is the point — so this arm
                // exists to keep the switch exhaustive without an `@unknown`-style catch-all that
                // would silently absorb a genuinely new case added later.
                EmptyView()
            }
        }
        .fullScreenCover(item: coverPresentation) { _ in
            PhotoViewerView(imageURL: imageURL, authorName: post.post.displayName)
        }
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
    }

    /// The sheet channel sees every case except the photo viewer; the cover channel sees only the
    /// photo viewer. Both write straight back to the single `presentation` value, so a swipe-down
    /// dismissal of either clears the same state the tap set.
    private var sheetPresentation: Binding<CardPresentation?> {
        Binding(get: { presentation?.isCover == true ? nil : presentation },
                set: { presentation = $0 })
    }

    private var coverPresentation: Binding<CardPresentation?> {
        Binding(get: { presentation?.isCover == true ? presentation : nil },
                set: { presentation = $0 })
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            RemoteAvatar(url: avatarURL, name: post.post.displayName, size: 40)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(post.post.displayName)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Palette.textPrimary)
                if let createdAt = post.post.createdAt {
                    Text(RelativeTime.caption.localizedString(for: createdAt, relativeTo: Date()))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .accessibilityLabel(RelativeTime.accessibility.localizedString(
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
                presentation = .report
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

    /// Tappable so the photo can be viewed full-screen (`PhotoViewerView`) instead of only ever
    /// showing as this fixed-height, `.scaledToFill`-cropped tile — a portrait photo here is
    /// necessarily a narrow cropped band, and until this there was no way to see the rest of it.
    /// A real `Button`, not a bare `.onTapGesture`: this card lives inside a `List` row alongside
    /// `CheersButton` and the comments button (`FeedView.swift:147`), and `docs/STATE_AUDIT.md`
    /// records a real defect where a plain `Button` *without* an explicit `.buttonStyle` in that
    /// same row let List's hit-testing route a tap to the wrong sibling control. `.buttonStyle
    /// (.plain)` here matches both of that row's existing controls (and `FriendsView.pendingRow`'s
    /// identical convention) so this third control gets its own independently hit-tested target
    /// rather than risking that failure mode a third time.
    ///
    /// The whole tile — loading spinner, loaded photo, or `photoUnavailablePlaceholder` alike —
    /// sits inside one `Button`, so SwiftUI collapses it to a single accessibility element
    /// regardless of `RemoteImage`'s phase; the tile's own content is `.accessibilityHidden` and
    /// the label/hint below are set once, directly on the `Button`, rather than trying to vary
    /// them per phase (the honest per-phase distinction — e.g. "Photo could not be loaded" — still
    /// exists, just inside `PhotoViewerView` once opened, not on this tile's tap target).
    @ViewBuilder
    private var photo: some View {
        if let imageURL {
            Button {
                presentation = .photo
            } label: {
                tile(for: imageURL)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("feed-post-photo-\(post.id)")
            .accessibilityLabel("Photo posted by \(post.post.displayName)")
            .accessibilityHint("Opens the photo full screen")
        }
    }

    /// **The tile's tap target must be the tile, and nothing outside it.**
    ///
    /// This used to be `RemoteImage { ZStack { … image.scaledToFill() } }.frame(maxHeight:
    /// photoHeight).clipShape(…)`. `scaledToFill` returns a size *larger* than the one it is
    /// proposed — that is what "fill" means — so the `ZStack` reported the whole un-cropped image
    /// rectangle as its size, e.g. 338×451 for a 3:4 phone photo in a 338×200 tile. The `.frame`
    /// above it still *reported* 200pt to the enclosing `VStack` (so the card laid out correctly
    /// and the picture looked right), and `.clipShape` clipped the *drawing* to 200pt — but
    /// neither clips **hit testing or the accessibility frame**. The `Button`'s tap target was
    /// therefore the full 451pt image rectangle, centred on a 200pt picture: 125pt of invisible,
    /// tappable photo overhanging the header above and the Cheers/comments row below. The
    /// post-options menu, which sits inside that overhang, became literally un-tappable — the
    /// photo is a later sibling in the `VStack`, so it won every hit test in the overlap.
    ///
    /// The fix is structural, not a magic number: a `Color` carries the tile's size, the image
    /// goes in an **`.overlay`** (an overlay is proposed its parent's size and can never inflate
    /// it, unlike a `ZStack` child), and `.contentShape` pins the interactive region to exactly
    /// the shape `.clipShape` draws. The label's layout size is now `photoHeight` in every
    /// `RemoteImagePhase` — spinner, image, or placeholder — and for every source aspect ratio,
    /// so the tap target cannot drift from the picture again. Nothing about the appearance
    /// changes: the same `scaledToFill` crop, the same rounded corners.
    private func tile(for imageURL: URL) -> some View {
        Theme.Palette.backgroundPrimary
            .frame(maxWidth: .infinity, minHeight: Self.photoHeight, maxHeight: Self.photoHeight)
            .overlay {
                RemoteImage(url: imageURL) { phase in
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
            .clipShape(Self.tileShape)
            .contentShape(Self.tileShape)
            .accessibilityHidden(true)
    }

    private static let tileShape = RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)

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
        // `.buttonStyle(.plain)` on each control below, matching the identical two-plain-Buttons-
        // in-one-HStack-in-a-List-row shape `FriendsView.pendingRow` already guards this way. With
        // no button style set at all, SwiftUI/UIKit's List row hit-testing can route a tap
        // anywhere in this HStack to the wrong sibling Button — confirmed the deterministic cause
        // of `docs/STATE_AUDIT.md`'s "tapping Cheers spuriously opens comments" defect, not a
        // timing race: `.plain` makes each control its own independently hit-tested target, no
        // wall-clock element involved. `.plain` also has no visual effect here (no chrome to
        // remove), so neither button's appearance changes.
        HStack {
            CheersButton(cheered: post.viewerHasCheered, count: post.cheersCount, action: onToggleCheers)
                .buttonStyle(.plain)
            Spacer(minLength: 0)
            Button {
                presentation = .comments
            } label: {
                Label("\(post.commentCount)", systemImage: "bubble.right")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .buttonStyle(.plain)
            .frame(minHeight: Theme.minTapTarget)
            .contentShape(Rectangle())
            .accessibilityIdentifier("post-comments-button")
            .accessibilityLabel(commentCountAccessibilityLabel)
            .accessibilityHint("Opens the comments for this post")
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
