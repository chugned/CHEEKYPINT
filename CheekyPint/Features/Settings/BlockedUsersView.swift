import SwiftUI
import CheekyPintCore

/// Manage blocked users (master prompt §18). Blocking overrides all other visibility.
struct BlockedUsersView: View {
    @Environment(\.container) private var container
    @State private var blocked: [FriendPreviewDTO] = []
    @State private var isLoading = false

    var body: some View {
        List {
            if blocked.isEmpty && !isLoading {
                StatusView(systemImage: "hand.raised", title: "No blocked users",
                           message: "Anyone you block will appear here.")
            }
            ForEach(blocked, id: \.userId) { user in
                HStack {
                    RemoteAvatar(url: container.avatarURL(for: user.avatarPath), name: user.displayName)
                    Text(user.displayName).foregroundStyle(Theme.Palette.textPrimary)
                    Spacer()
                    Button("Unblock") { Task { await unblock(user) } }
                        .font(Theme.Typography.callout).tint(Theme.Palette.accent)
                }
                .listRowBackground(Theme.Palette.backgroundSecondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.backgroundPrimary)
        .navigationTitle("Blocked users")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        isLoading = true; defer { isLoading = false }
        blocked = (try? await container.friends.fetchBlockedUsers()) ?? []
    }

    private func unblock(_ user: FriendPreviewDTO) async {
        try? await container.friends.unblock(user.userId)
        await load()
    }
}
