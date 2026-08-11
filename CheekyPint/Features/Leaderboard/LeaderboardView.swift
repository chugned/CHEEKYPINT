import SwiftUI
import CheekyPintCore

/// The beer leaderboard. The top drinker is crowned King and the podium is styled gold,
/// silver, and bronze.
struct LeaderboardView: View {
    @Environment(\.container) private var container
    let profile: Profile

    @State private var period: LeaderboardPeriod = .week
    @State private var rows: [LeaderboardRow] = []
    @State private var receivedCheers: [UUID: CheersDTO] = [:]
    @State private var sentCheers: Set<UUID> = []
    @State private var pendingCheers: Set<UUID> = []
    @State private var isLoading = false
    @State private var error: SupabaseError?
    @State private var cheersConfirmation: String?
    @State private var cheersError: String?

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
        .alert("Couldn't send Cheers", isPresented: Binding(
            get: { cheersError != nil },
            set: { if !$0 { cheersError = nil } }
        )) {
            Button("OK", role: .cancel) { cheersError = nil }
        } message: {
            Text(cheersError ?? "Please try again.")
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

                if let cheersConfirmation {
                    Label(cheersConfirmation, systemImage: "hands.clap.fill")
                        .font(Theme.Typography.callout.weight(.semibold))
                        .foregroundStyle(Theme.Palette.accent)
                        .listRowBackground(Theme.Palette.backgroundSecondary)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                ForEach(rows) { row in
                    LeaderboardRowView(
                        row: row,
                        avatarURL: container.avatarURL(for: row.avatarPath),
                        cheersState: cheersState(for: row),
                        onCheers: row.isCurrentUser ? nil : {
                            Task { await sendCheers(to: row) }
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
            async let incomingCheers = container.friends.fetchReceivedCheers()
            rows = try await leaderboardRows
            let incoming = try await incomingCheers
            receivedCheers = Dictionary(uniqueKeysWithValues: incoming.map { ($0.senderId, $0) })
            sentCheers.subtract(receivedCheers.keys)
        } catch let e as SupabaseError {
            error = e
        } catch {
            self.error = .unknown("Couldn't load standings.")
        }
    }

    private func cheersState(for row: LeaderboardRow) -> CheersButtonState? {
        guard !row.isCurrentUser else { return nil }
        if pendingCheers.contains(row.id) { return .sending }
        if receivedCheers[row.id] != nil { return .received }
        if sentCheers.contains(row.id) { return .sent }
        return .available
    }

    private func sendCheers(to row: LeaderboardRow) async {
        guard !row.isCurrentUser, !pendingCheers.contains(row.id) else { return }
        pendingCheers.insert(row.id)
        defer { pendingCheers.remove(row.id) }

        do {
            try await container.friends.sendCheers(to: row.id)
            receivedCheers.removeValue(forKey: row.id)
            sentCheers.insert(row.id)
            cheersConfirmation = "Cheers sent to \(row.displayName)"
            Haptics.success()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                if cheersConfirmation == "Cheers sent to \(row.displayName)" {
                    cheersConfirmation = nil
                }
            }
        } catch let e as SupabaseError {
            cheersError = e.friendlyMessage
        } catch {
            cheersError = "Couldn't send Cheers. Please try again."
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
