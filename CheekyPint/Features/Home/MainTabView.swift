import SwiftUI
import CheekyPintCore

/// The deliberately small CheekyPint experience: log beers, see the leaderboard, and manage
/// settings. Pub discovery, sessions, profiles, and friend-management are not part of this UI.
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

            NavigationStack {
                SettingsView()
            }
            .tabItem { Label("Settings", systemImage: "gearshape.fill") }
            .tag(3)
        }
        .tint(Theme.Palette.accent)
    }
}

// Some legacy friend views remain in the target for source compatibility even though they are
// no longer reachable from the app shell.
extension FriendToken: @retroactive Identifiable {
    public var id: String { rawValue }
}
