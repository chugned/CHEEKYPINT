import SwiftUI
import CheekyPintCore

/// The composition root. Constructed once at launch and passed through the SwiftUI environment.
/// Repositories are cheap value types built on demand from the shared `auth` + `data` clients.
struct AppContainer: Sendable {
    let config: AppConfig
    let auth: SupabaseAuth
    let data: SupabaseData
    let analytics: any AnalyticsService

    /// `auth` is injectable for one reason: `SupabaseAuth` persists into the Keychain under a
    /// fixed service name, and the app and its unit-test bundle share a bundle id and therefore
    /// share that Keychain. A test that signs in for real would otherwise leave a live session
    /// behind for the UI tests to launch into, and they expect the welcome screen. Tests pass a
    /// `SupabaseAuth` built on a per-test Keychain service; the app never passes anything.
    init(config: AppConfig = .current, analytics: any AnalyticsService = NoOpAnalytics(),
         auth: SupabaseAuth? = nil) {
        let auth = auth ?? SupabaseAuth(config: config)
        self.config = config
        self.auth = auth
        self.data = SupabaseData(config: config, auth: auth)
        self.analytics = analytics
    }

    var profiles: ProfileRepository { ProfileRepository(data: data) }
    var diary: DiaryRepository { DiaryRepository(data: data) }
    var friends: FriendsRepository { FriendsRepository(data: data) }
    var leaderboard: LeaderboardRepository { LeaderboardRepository(data: data) }
    var friendActivity: FriendActivityRepository { FriendActivityRepository(data: data) }
    var pubs: PubsRepository { PubsRepository(data: data) }
    var sessions: SessionsRepository { SessionsRepository(data: data) }
    var feed: FeedRepository { FeedRepository(data: data) }

    let deepLinkParser = DeepLinkParser()

    /// Public URL for an avatar storage path (nil-safe). Used wherever a friend/leaderboard row
    /// carries an `avatarPath`.
    func avatarURL(for path: String?) -> URL? {
        profiles.avatarURL(for: path)
    }
}

private struct AppContainerKey: EnvironmentKey {
    static let defaultValue = AppContainer()
}

extension EnvironmentValues {
    var container: AppContainer {
        get { self[AppContainerKey.self] }
        set { self[AppContainerKey.self] = newValue }
    }
}
