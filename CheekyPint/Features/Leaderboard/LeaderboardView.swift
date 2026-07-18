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
                LeaderboardRowView(row: row, avatarURL: container.avatarURL(for: row.avatarPath))
                    .listRowBackground(Theme.Palette.backgroundSecondary)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func load() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            rows = try await container.leaderboard.fullLeaderboard(period: period, profile: profile, session: activeSession)
        } catch let e as SupabaseError {
            error = e
        } catch {
            self.error = .unknown("Couldn't load standings.")
        }
    }
}
