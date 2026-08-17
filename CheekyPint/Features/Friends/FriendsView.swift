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

    /// Accept or decline, and say so when it didn't work.
    ///
    /// This used to be `try?`. A failure then left the row sitting in Requests with nothing on
    /// screen to explain it — indistinguishable from a tap that missed the button, and the reason
    /// `FriendFlowUITests` has to gate the friendship on `get_friends()`'s empty state rather than
    /// on any error surface.
    ///
    /// The order matters. `load()` opens with `error = nil`, so re-loading after a failure would
    /// wipe the message that failure just produced. On a failure there is nothing new to load
    /// anyway — the RPC changed nothing — so this returns instead, and only a success re-reads the
    /// lists.
    func respond(_ request: PendingRequestDTO, accept: Bool) async {
        do {
            try await container.friends.respond(to: request.friendshipId, accept: accept)
        } catch {
            // The same single surface `load()` uses, and the same `.unknown(_)` idiom it already
            // uses one method above for copy it wrote itself — `.unknown`'s `friendlyMessage` is
            // its payload verbatim, so the sentence below is what the user reads.
            self.error = .unknown(
                FriendsView.respondFailureMessage(for: error, accepting: accept,
                                                  name: request.displayName))
            return
        }
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
    @State private var showQR = false

    var body: some View {
        NavigationStack {
            Group {
                if let model { list(model) } else { ProgressView().tint(Theme.Palette.accent) }
            }
            .pubBackground()
            .navigationTitle("Friends")
            .toolbar {
                // "Here's my code, here's where I add yours" — My QR and Add-a-friend live side
                // by side rather than My QR hanging off the unreachable `ProfileView`.
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { AddFriendView() } label: { Image(systemName: "person.badge.plus") }
                        .accessibilityLabel("Add a friend")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showQR = true } label: { Image(systemName: "qrcode") }
                        .accessibilityIdentifier("friends-my-qr-button")
                        .accessibilityLabel("My QR code")
                }
            }
        }
        .sheet(isPresented: $showQR) { MyQRView() }
        .task {
            if model == nil { model = FriendsViewModel(container: container) }
            await model?.load()
        }
    }

    /// Display copy for a failed accept/decline. `static` so it can be exercised directly without
    /// standing up a view, a view model or a container — the same shape as
    /// `DataExportView.errorMessage(for:)` and `FeedView.errorIcon(for:)`.
    ///
    /// Two things have to be in the sentence and `SupabaseError.friendlyMessage` supplies neither.
    ///
    /// **Which action didn't happen.** On success the row leaves the Requests section, and that
    /// disappearance is the only confirmation the screen gives; a row that stays put reads as a
    /// tap that missed, not as a refusal. So the copy names the action and the person.
    ///
    /// **What `.notFound` means here.** It is the realistic failure of this RPC.
    /// `respond_to_friend_request` (`supabase/migrations/20260101000800_rpc_social.sql:141`) raises
    /// `P0002 'Request not found'` for any row that is no longer `pending` with the caller as
    /// addressee — the sender withdrew it, it was already answered on another device, or that
    /// account is gone. `friendlyMessage` renders `.notFound` as "That's not available.", which on
    /// this screen names nothing and suggests nothing. Every other case keeps its own copy, which
    /// is already written for a user to act on: `.offline` says it will retry, `.notAuthenticated`
    /// says to sign in, and `.rateLimited` carries the server's own hint.
    static func respondFailureMessage(for error: Error, accepting: Bool, name: String) -> String {
        let action = accepting ? "accept" : "decline"
        guard let error = error as? SupabaseError else {
            return "Couldn't \(action) \(name)'s request. Please try again."
        }
        if case .notFound = error {
            return "Couldn't \(action) \(name)'s request — it's no longer waiting. They may have " +
                   "withdrawn it, or it was already answered. Pull down to refresh."
        }
        return "Couldn't \(action) \(name)'s request. \(error.friendlyMessage)"
    }

    @ViewBuilder
    private func list(_ model: FriendsViewModel) -> some View {
        List {
            // The one error surface on this screen, shared by `load()` and `respond(_:accept:)`.
            // `load()` had captured its failures into `error` since this file was written, but
            // nothing ever rendered that property, so a friends list that failed to load was as
            // silent as a failed accept.
            if let error = model.error {
                Text(error.friendlyMessage)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Palette.warning)
                    .accessibilityIdentifier("friends-error-message")
            }
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
