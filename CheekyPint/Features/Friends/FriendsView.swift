import SwiftUI
import CheekyPintCore

@MainActor
@Observable
final class FriendsViewModel {
    let container: AppContainer
    private(set) var friends: [FriendDTO] = []
    private(set) var pending: [PendingRequestDTO] = []
    private(set) var isLoading = false
    var error: SupabaseError?

    init(container: AppContainer) { self.container = container }

    func load() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            async let friends = container.friends.fetchFriends()
            async let pending = container.friends.fetchPendingRequests()
            self.friends = try await friends
            self.pending = try await pending
        } catch let e as SupabaseError { error = e } catch { self.error = .unknown("Couldn't load friends.") }
    }

    func respond(_ request: PendingRequestDTO, accept: Bool) async {
        try? await container.friends.respond(to: request.friendshipId, accept: accept)
        if accept { container.analytics.track(.friendRequestAccepted) }
        await load()
    }

    func remove(_ friend: FriendDTO) async {
        try? await container.friends.removeFriend(friend.userId)
        await load()
    }
}

/// Friends list + pending requests (master prompt §8). Add via QR/scan/manual.
struct FriendsView: View {
    @Environment(\.container) private var container
    @State private var model: FriendsViewModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model { list(model) } else { ProgressView().tint(Theme.Palette.accent) }
            }
            .pubBackground()
            .navigationTitle("Friends")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { AddFriendView() } label: { Image(systemName: "person.badge.plus") }
                        .accessibilityLabel("Add a friend")
                }
            }
        }
        .task {
            if model == nil { model = FriendsViewModel(container: container) }
            await model?.load()
        }
    }

    @ViewBuilder
    private func list(_ model: FriendsViewModel) -> some View {
        List {
            if !model.pending.isEmpty {
                Section("Requests") {
                    ForEach(model.pending) { request in
                        pendingRow(model, request)
                    }
                }
            }
            Section("Mates") {
                if model.friends.isEmpty {
                    Text("No mates yet. Tap + to share your code.")
                        .foregroundStyle(Theme.Palette.textSecondary)
                } else {
                    ForEach(model.friends) { friend in
                        NavigationLink { FriendProfileView(userID: friend.userId, name: friend.displayName) } label: {
                            HStack(spacing: Theme.Spacing.md) {
                                RemoteAvatar(url: container.avatarURL(for: friend.avatarPath), name: friend.displayName)
                                Text(friend.displayName).foregroundStyle(Theme.Palette.textPrimary)
                            }
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { Task { await model.remove(friend) } }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable { await model.load() }
    }

    private func pendingRow(_ model: FriendsViewModel, _ request: PendingRequestDTO) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            RemoteAvatar(url: container.avatarURL(for: request.avatarPath), name: request.displayName)
            Text(request.displayName).foregroundStyle(Theme.Palette.textPrimary)
            Spacer()
            Button { Task { await model.respond(request, accept: true) } } label: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Palette.success)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Accept \(request.displayName)")
            Button { Task { await model.respond(request, accept: false) } } label: {
                Image(systemName: "xmark.circle").foregroundStyle(Theme.Palette.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Decline \(request.displayName)")
        }
    }
}
