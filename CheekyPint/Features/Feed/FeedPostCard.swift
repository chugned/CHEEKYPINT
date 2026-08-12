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
                    Text(createdAt, style: .relative)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            Spacer(minLength: 0)
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
                        Image(systemName: "photo")
                            .font(.system(size: 28))
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fill)
            .frame(maxWidth: .infinity)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        }
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
            Label("\(post.post.commentCount)", systemImage: "bubble.right")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .accessibilityLabel(commentCountAccessibilityLabel)
        }
    }

    private var commentCountAccessibilityLabel: String {
        post.post.commentCount == 1 ? "1 comment" : "\(post.post.commentCount) comments"
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
