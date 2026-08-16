import SwiftUI
import CheekyPintCore

/// Logger, Feed, Leaderboard, Friends, and Settings. Pub discovery and sessions are not part of
/// this UI. Friends gates the feed (friends-only posts), the leaderboard, and @mention
/// autocomplete, so it gets a top-level tab rather than being buried behind another screen.
struct MainTabView: View {
    @Environment(SessionController.self) private var session
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            HomeView()
                .tabItem { Label("Logger", systemImage: "mug.fill") }
                .tag(0)

            FeedView()
                .tabItem { Label("Feed", systemImage: "square.stack") }
                .tag(1)

            NavigationStack {
                if let profile = session.currentProfile {
                    LeaderboardView(profile: profile)
                }
            }
            .tabItem { Label("Leaderboard", systemImage: "trophy.fill") }
            .tag(2)

            // `FriendsView` wraps itself in its own `NavigationStack` (like `HomeView`/`FeedView`
            // above), so it is placed directly here rather than wrapped again — an outer
            // `NavigationStack` around an already self-wrapping view would double-nest.
            FriendsView()
                .tabItem { Label("Friends", systemImage: "person.2.fill") }
                .tag(3)

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
            .tag(4)
        }
        .tint(Theme.Palette.accent)
    }
}

extension FriendToken: @retroactive Identifiable {
    public var id: String { rawValue }
}
