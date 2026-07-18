import SwiftUI
import CheekyPintCore

/// The full friend leaderboard (master prompt §9). Period-switchable, neutral treatment,
/// "Private" for hidden totals, current user marked. No global leaderboard exists.
struct LeaderboardView: View {
    @Environment(\.container) private var container
    let profile: Profile
    let activeSession: PubSession?

    @State private var period: LeaderboardPeriod = .week
    @State private var rows: [LeaderboardRow] = []
    @State private var activities: [UUID: FriendBeerActivity] = [:]
    @State private var selectedActivity: FriendBeerActivity?
    @State private var isLoading = false
    @State private var error: SupabaseError?

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            Picker("Period", selection: $period) {
                ForEach(LeaderboardPeriod.allCases) { Text($0.leaderboardTitle).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Theme.Spacing.lg)
            .onChange(of: period) { _, _ in Task { await load() } }

            content
        }
        .pubBackground()
        .navigationTitle("Standings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if activeSession != nil { period = .session }
            await load()
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && rows.isEmpty {
            ProgressView().tint(Theme.Palette.accent).frame(maxHeight: .infinity)
        } else if let error {
            StatusView(systemImage: "wifi.slash", title: "Couldn't load standings",
                       message: error.friendlyMessage, actionTitle: "Retry") { Task { await load() } }
        } else if rows.isEmpty {
            StatusView(systemImage: "person.2", title: "No standings yet",
                       message: "Add a mate or log your first pub visit.")
        } else {
            List(rows) { row in
                if let activity = activities[row.id] {
                    Button { selectedActivity = activity } label: {
                        LeaderboardRowView(
                            row: row,
                            avatarURL: container.avatarURL(for: row.avatarPath),
                            activity: activity
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Theme.Palette.backgroundSecondary)
                } else {
                    LeaderboardRowView(
                        row: row,
                        avatarURL: container.avatarURL(for: row.avatarPath),
                        activity: nil
                    )
                    .listRowBackground(Theme.Palette.backgroundSecondary)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .sheet(item: $selectedActivity) { activity in
                FriendBeerActivityDetailView(
                    activity: activity,
                    avatarURL: container.avatarURL(for: activity.avatarPath)
                )
            }
        }
    }

    private func load() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            async let leaderboardRows = container.leaderboard.fullLeaderboard(period: period, profile: profile, session: activeSession)
            async let beerActivities = container.friendActivity.beerActivities()
            rows = try await leaderboardRows
            activities = try await Dictionary(uniqueKeysWithValues: beerActivities.map { ($0.userID, $0) })
        } catch let e as SupabaseError {
            error = e
        } catch {
            self.error = .unknown("Couldn't load standings.")
        }
    }
}

private struct FriendBeerActivityDetailView: View {
    let activity: FriendBeerActivity
    let avatarURL: URL?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: Theme.Spacing.md) {
                        RemoteAvatar(url: avatarURL, name: activity.displayName, size: 58)
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text(activity.displayName)
                                .font(Theme.Typography.title)
                                .foregroundStyle(Theme.Palette.textPrimary)
                            Text(activity.nowText)
                                .font(Theme.Typography.callout)
                                .foregroundStyle(Theme.Palette.accent)
                        }
                    }
                }

                if let pubName = activity.currentPubName {
                    Section("Right now") {
                        Label(pubName, systemImage: "mappin.and.ellipse")
                        if let currentBeerName = activity.currentBeerName {
                            Label(currentBeerName, systemImage: "mug.fill")
                        }
                        if let address = activity.currentPubAddress {
                            Text(address)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                }

                Section("Top pubs") {
                    if activity.topPubs.isEmpty {
                        Text("No pub recommendations yet.")
                            .font(Theme.Typography.callout)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    } else {
                        ForEach(Array(activity.topPubs.enumerated()), id: \.element.id) { index, pub in
                            TopPubMedalRow(pub: pub, rank: index + 1)
                        }
                    }
                }

                Section("Drink history") {
                    ForEach(activity.recentLogs) { log in
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text(log.beerName)
                                .font(Theme.Typography.headline)
                                .foregroundStyle(Theme.Palette.textPrimary)
                            if let pubName = log.pubName {
                                Text(pubName)
                                    .font(Theme.Typography.callout)
                                    .foregroundStyle(Theme.Palette.accent)
                            }
                            Text(log.occurredAt.formatted(date: .abbreviated, time: .shortened))
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.backgroundPrimary)
            .navigationTitle("Beer intel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct TopPubMedalRow: View {
    let pub: FriendTopPub
    let rank: Int

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            medal
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(pub.name)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("\(pub.visitCount) visit\(pub.visitCount == 1 ? "" : "s")")
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Palette.accent)
                if let address = pub.address {
                    Text(address)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }

    private var medal: some View {
        ZStack {
            Circle()
                .fill(medalColor)
                .shadow(color: medalColor.opacity(0.32), radius: 6, y: 2)
            Text(medalText)
                .font(.system(size: 17, weight: .black, design: .rounded))
                .foregroundStyle(.white)
        }
        .accessibilityLabel(medalAccessibility)
    }

    private var medalText: String {
        switch rank {
        case 1: return "G"
        case 2: return "S"
        default: return "B"
        }
    }

    private var medalAccessibility: String {
        switch rank {
        case 1: return "Gold"
        case 2: return "Silver"
        default: return "Bronze"
        }
    }

    private var medalColor: Color {
        switch rank {
        case 1: return Color(red: 0.93, green: 0.63, blue: 0.13)
        case 2: return Color(red: 0.58, green: 0.62, blue: 0.66)
        default: return Color(red: 0.67, green: 0.39, blue: 0.18)
        }
    }
}
