import SwiftUI
import CheekyPintCore

/// The four primary destinations (master prompt §6). The log button lives on Home as the
/// visual centre, so it is not a tab. Handles inbound friend/session deep links by presenting
/// the right sheet.
struct MainTabView: View {
    @Environment(SessionController.self) private var session
    @State private var selection = 0
    @State private var friendToken: FriendToken?
    @State private var sessionToken: FriendToken?

    var body: some View {
        TabView(selection: $selection) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }.tag(0)
            FriendsView()
                .tabItem { Label("Friends", systemImage: "person.2.fill") }.tag(1)
            PubsView()
                .tabItem { Label("Pubs", systemImage: "mappin.and.ellipse") }.tag(2)
            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }.tag(3)
        }
        .tint(Theme.Palette.accent)
        .onChange(of: session.pendingDeepLink) { _, _ in routeDeepLink() }
        .onAppear(perform: routeDeepLink)
        .sheet(item: $friendToken) { token in
            NavigationStack { FriendPreviewView(token: token) }
        }
        .sheet(item: $sessionToken) { token in
            NavigationStack { JoinSessionView(token: token) }
        }
    }

    private func routeDeepLink() {
        guard let link = session.consumeDeepLink() else { return }
        switch link {
        case .addFriend(let token): friendToken = token
        case .joinSession(let token): sessionToken = token
        }
    }
}

// FriendToken is Identifiable for `.sheet(item:)`.
extension FriendToken: @retroactive Identifiable {
    public var id: String { rawValue }
}
