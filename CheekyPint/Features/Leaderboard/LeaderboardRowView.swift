import SwiftUI
import CheekyPintCore

/// A single leaderboard/standings row. Neutral treatment — no medals or "winner" styling
/// (master prompt §9). Rank is shown as text AND the current user gets a non-colour marker so
/// rank/status don't rely on colour alone (§21). Private friends show "Private", never a zero.
struct LeaderboardRowView: View {
    let row: LeaderboardRow
    var avatarURL: URL?

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            rankBadge
            RemoteAvatar(url: avatarURL, name: row.displayName, size: 40)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.displayName)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Palette.textPrimary)
                if row.isCurrentUser {
                    Text("You").font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            Spacer()
            valueLabel
        }
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var rankBadge: some View {
        Text(row.rank.map(String.init) ?? "—")
            .font(Theme.Typography.headline.monospacedDigit())
            .foregroundStyle(row.isCurrentUser ? Theme.Palette.accent : Theme.Palette.textSecondary)
            .frame(width: 28, alignment: .center)
    }

    @ViewBuilder
    private var valueLabel: some View {
        if row.isPrivate {
            Text("Private")
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.textSecondary)
                .italic()
        } else {
            let count = Int(row.value ?? 0)
            Text("\(count)")
                .font(Theme.Typography.title.monospacedDigit())
                .foregroundStyle(Theme.Palette.textPrimary)
        }
    }

    private var accessibilityText: String {
        let rank = row.rank.map { "Rank \($0)." } ?? ""
        let who = row.isCurrentUser ? "You, \(row.displayName)." : row.displayName + "."
        let value = row.isPrivate ? "Private." : "\(Int(row.value ?? 0)) pints recorded."
        return "\(rank) \(who) \(value)"
    }
}
