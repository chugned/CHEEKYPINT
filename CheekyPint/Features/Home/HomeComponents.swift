import SwiftUI
import CheekyPintCore

/// Compact top-three-plus-you standings on Home (master prompt §7).
struct StandingsPreview: View {
    @Environment(\.container) private var container
    let rows: [LeaderboardRow]
    let period: LeaderboardPeriod
    var activities: [UUID: FriendBeerActivity] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Text("Friend standings").font(Theme.Typography.headline).foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                Text(period.leaderboardTitle).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textSecondary)
            }
            if rows.isEmpty {
                Text("No standings yet. Add a mate or log your first pub visit.")
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(rows) { row in
                    LeaderboardRowView(
                        row: row,
                        avatarURL: container.avatarURL(for: row.avatarPath),
                        activity: activities[row.id]
                    )
                }
            }
        }
        .coasterCard()
    }
}

/// The "active friends in this session" strip (master prompt §7). Does not expose live location —
/// only that an accepted friend deliberately joined the same session.
struct ActiveFriendsStrip: View {
    let members: [SessionMember]
    let session: PubSession?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("At the session")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.Palette.textPrimary)
            if members.count <= 1 {
                Text("No mates have joined yet. Share the session code to get a round in.")
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Palette.textSecondary)
            } else {
                Text("\(members.count) here now")
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .coasterCard()
    }
}
