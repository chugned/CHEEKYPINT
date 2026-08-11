import SwiftUI
import CheekyPintCore

/// The beer leaderboard. The top drinker is crowned King and the podium is styled gold,
/// silver, and bronze.
struct LeaderboardView: View {
    @Environment(\.container) private var container
    let profile: Profile

    @State private var period: LeaderboardPeriod = .week
    @State private var rows: [LeaderboardRow] = []
    @State private var receivedNudges: [UUID: NudgeDTO] = [:]
    @State private var sentNudges: Set<UUID> = []
    @State private var pendingNudges: Set<UUID> = []
    @State private var isLoading = false
    @State private var error: SupabaseError?
    @State private var nudgeConfirmation: String?
    @State private var nudgeError: String?

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            Picker("Period", selection: $period) {
                ForEach([LeaderboardPeriod.week, .month, .year]) {
                    Text($0.leaderboardTitle).tag($0)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Theme.Spacing.lg)
            .onChange(of: period) { _, _ in Task { await load() } }

            content
        }
        .pubBackground()
        .navigationTitle("Leaderboard")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { Task { await load() } }
        .alert("Couldn't send Nudge", isPresented: Binding(
            get: { nudgeError != nil },
            set: { if !$0 { nudgeError = nil } }
        )) {
            Button("OK", role: .cancel) { nudgeError = nil }
        } message: {
            Text(nudgeError ?? "Please try again.")
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
            StatusView(systemImage: "trophy", title: "No leaderboard yet",
                       message: "Log the first beer to start the race for the crown.")
        } else {
            List {
                if let king = rows.first(where: { $0.rank == 1 && !$0.isPrivate }) {
                    KingBanner(
                        row: king,
                        avatarURL: container.avatarURL(for: king.avatarPath),
                        period: period
                    )
                    .listRowBackground(Theme.Palette.backgroundSecondary)
                }

                if let nudgeConfirmation {
                    Label(nudgeConfirmation, systemImage: "hand.wave.fill")
                        .font(Theme.Typography.callout.weight(.semibold))
                        .foregroundStyle(Theme.Palette.accent)
                        .listRowBackground(Theme.Palette.backgroundSecondary)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                ForEach(rows) { row in
                    LeaderboardRowView(
                        row: row,
                        avatarURL: container.avatarURL(for: row.avatarPath),
                        nudgeState: nudgeState(for: row),
                        onNudge: row.isCurrentUser ? nil : {
                            Task { await sendNudge(to: row) }
                        }
                    )
                    .listRowBackground(Theme.Palette.backgroundSecondary)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await load() }
        }
    }

    private func load() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            async let leaderboardRows = container.leaderboard.fullLeaderboard(
                period: period,
                profile: profile,
                session: nil
            )
            async let incomingNudges = container.friends.fetchReceivedNudges()
            rows = try await leaderboardRows
            // Non-fatal: a nudge-fetch failure shouldn't blank standings that already loaded.
            let incoming = (try? await incomingNudges) ?? []
            receivedNudges = Dictionary(uniqueKeysWithValues: incoming.map { ($0.senderId, $0) })
            sentNudges.subtract(receivedNudges.keys)
        } catch let e as SupabaseError {
            error = e
        } catch {
            self.error = .unknown("Couldn't load standings.")
        }
    }

    private func nudgeState(for row: LeaderboardRow) -> NudgeButtonState? {
        guard !row.isCurrentUser else { return nil }
        if pendingNudges.contains(row.id) { return .sending }
        if receivedNudges[row.id] != nil { return .received }
        if sentNudges.contains(row.id) { return .sent }
        return .available
    }

    private func sendNudge(to row: LeaderboardRow) async {
        guard !row.isCurrentUser, !pendingNudges.contains(row.id) else { return }
        pendingNudges.insert(row.id)
        defer { pendingNudges.remove(row.id) }

        do {
            try await container.friends.sendNudge(to: row.id)
            receivedNudges.removeValue(forKey: row.id)
            sentNudges.insert(row.id)
            nudgeConfirmation = "Nudge sent to \(row.displayName)"
            Haptics.success()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                if nudgeConfirmation == "Nudge sent to \(row.displayName)" {
                    nudgeConfirmation = nil
                }
            }
        } catch let e as SupabaseError {
            nudgeError = e.friendlyMessage
        } catch {
            nudgeError = "Couldn't send Nudge. Please try again."
        }
    }
}

private struct KingBanner: View {
    let row: LeaderboardRow
    let avatarURL: URL?
    let period: LeaderboardPeriod

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.93, green: 0.63, blue: 0.13).opacity(0.2))
                Image(systemName: "crown.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Color(red: 0.93, green: 0.63, blue: 0.13))
            }
            .frame(width: 58, height: 58)

            RemoteAvatar(url: avatarURL, name: row.displayName, size: 48)

            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text("KING")
                    .font(Theme.Typography.caption.weight(.black))
                    .foregroundStyle(Color(red: 0.93, green: 0.63, blue: 0.13))
                Text(row.displayName)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("\(Int(row.value ?? 0)) beers · \(period.leaderboardTitle.lowercased())")
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .padding(.vertical, Theme.Spacing.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("King, \(row.displayName), \(Int(row.value ?? 0)) beers")
    }
}
