import SwiftUI
import CheekyPintCore

enum NudgeButtonState {
    case available
    case received
    case sent
    case sending

    var label: String {
        switch self {
        case .available: return "Nudge"
        case .received: return "Nudge back"
        case .sent: return "Sent"
        case .sending: return "Sending"
        }
    }

    var systemImage: String {
        switch self {
        case .sent: return "checkmark"
        default: return "hands.clap.fill"
        }
    }
}

/// A leaderboard row with explicit gold, silver, and bronze podium styling.
struct LeaderboardRowView: View {
    let row: LeaderboardRow
    var avatarURL: URL?
    var nudgeState: NudgeButtonState?
    var onNudge: (() -> Void)?

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
                } else if nudgeState == .received {
                    Text("Cheered you")
                        .font(Theme.Typography.caption.weight(.semibold))
                        .foregroundStyle(Theme.Palette.accent)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: Theme.Spacing.xxs) {
                valueLabel
                nudgeButton
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    @ViewBuilder
    private var nudgeButton: some View {
        if let nudgeState, let onNudge {
            Button(action: onNudge) {
                Label(nudgeState.label, systemImage: nudgeState.systemImage)
            }
            .font(Theme.Typography.caption.weight(.semibold))
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(nudgeState == .received ? Theme.Palette.accent : Theme.Palette.textSecondary)
            .disabled(nudgeState == .sent || nudgeState == .sending)
            .accessibilityHint(nudgeState == .received
                ? "Sends a Nudge back to this friend"
                : "Sends a Nudge to this friend")
        }
    }

    private var rankBadge: some View {
        ZStack {
            if let rank = row.rank, rank <= 3 {
                Circle()
                    .fill(podiumColor(for: rank))
                    .shadow(color: podiumColor(for: rank).opacity(0.3), radius: 4, y: 2)
                Image(systemName: rank == 1 ? "crown.fill" : "medal.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Text(row.rank.map(String.init) ?? "—")
                    .font(Theme.Typography.headline.monospacedDigit())
                    .foregroundStyle(row.isCurrentUser ? Theme.Palette.accent : Theme.Palette.textSecondary)
            }
        }
        .frame(width: 34, height: 34)
        .accessibilityLabel(rankAccessibility)
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

    private var rankAccessibility: String {
        switch row.rank {
        case 1: return "King, gold"
        case 2: return "Second place, silver"
        case 3: return "Third place, bronze"
        case let rank?: return "Rank \(rank)"
        case nil: return "Unranked"
        }
    }

    private func podiumColor(for rank: Int) -> Color {
        switch rank {
        case 1: return Color(red: 0.93, green: 0.63, blue: 0.13)
        case 2: return Color(red: 0.58, green: 0.62, blue: 0.66)
        default: return Color(red: 0.67, green: 0.39, blue: 0.18)
        }
    }
}
