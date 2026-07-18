import SwiftUI
import CheekyPintCore

/// A friend's profile, subject to their privacy settings (master prompt §10). The server
/// returns only permitted fields; the client just presents whatever came back. Includes
/// remove/block/report actions.
struct FriendProfileView: View {
    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss
    let userID: UUID
    let name: String

    @State private var profile: FriendProfileDTO?
    @State private var favouritePubs: [FavouritePubDTO] = []
    @State private var error: SupabaseError?
    @State private var showReport = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                if let profile {
                    header(profile)
                    if let bio = profile.bio, !bio.isEmpty {
                        Text(bio).font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)
                    }
                    if !favouritePubs.isEmpty { favouritePubsCard }
                } else if let error {
                    StatusView(systemImage: "lock", title: "Not available", message: error.friendlyMessage)
                } else {
                    ProgressView().tint(Theme.Palette.accent)
                }
            }
            .padding(Theme.Spacing.lg)
        }
        .pubBackground()
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Remove friend", role: .destructive) { Task { await remove() } }
                    Button("Block", role: .destructive) { Task { await block() } }
                    Button("Report") { showReport = true }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showReport) { ReportUserView(userID: userID) }
        .task { await load() }
    }

    private func header(_ profile: FriendProfileDTO) -> some View {
        VStack(spacing: Theme.Spacing.sm) {
            RemoteAvatar(url: container.avatarURL(for: profile.avatarPath), name: profile.displayName, size: 96)
            Text(profile.displayName).font(Theme.Typography.largeTitle).foregroundStyle(Theme.Palette.textPrimary)
            if let username = profile.username { Text("@\(username)").font(Theme.Typography.callout).foregroundStyle(Theme.Palette.textSecondary) }
            if let city = profile.city { Label(city, systemImage: "mappin").font(Theme.Typography.callout).foregroundStyle(Theme.Palette.textSecondary) }
            if let since = profile.friendSince {
                Text("Mates since \(since.formatted(date: .abbreviated, time: .omitted))")
                    .font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textSecondary)
            }
        }
    }

    private var favouritePubsCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Regular haunts").font(Theme.Typography.headline).foregroundStyle(Theme.Palette.textPrimary)
            ForEach(favouritePubs) { pub in
                HStack {
                    VStack(alignment: .leading) {
                        Text(pub.name).foregroundStyle(Theme.Palette.textPrimary)
                        if let city = pub.city { Text(city).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textSecondary) }
                    }
                    Spacer()
                    Text("\(pub.visitCount) visits").font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .coasterCard()
    }

    private func load() async {
        do {
            profile = try await container.friends.fetchFriendProfile(userID)
            favouritePubs = (try? await container.friends.fetchFavouritePubs(of: userID)) ?? []
        } catch let e as SupabaseError { error = e } catch { self.error = .unknown("Not available.") }
    }

    private func remove() async {
        try? await container.friends.removeFriend(userID); dismiss()
    }

    private func block() async {
        try? await container.friends.block(userID); dismiss()
    }
}
