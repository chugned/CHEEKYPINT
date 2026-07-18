import Foundation

/// Per-user field visibility. Every shareable surface has its own switch so a user can,
/// for example, keep totals visible to friends while hiding their city and favourite pubs.
/// Maps to the `privacy_settings` table.
public struct PrivacySettings: Codable, Sendable, Hashable {
    public var userId: UUID
    public var profileVisibility: Visibility
    public var avatarVisibility: Visibility
    public var cityVisibility: Visibility
    public var sessionTotalVisibility: Visibility
    public var weeklyTotalVisibility: Visibility
    public var monthlyTotalVisibility: Visibility
    public var yearlyTotalVisibility: Visibility
    public var favouritePubsVisibility: Visibility
    public var sharedSessionsVisibility: Visibility

    public init(
        userId: UUID,
        profileVisibility: Visibility,
        avatarVisibility: Visibility,
        cityVisibility: Visibility,
        sessionTotalVisibility: Visibility,
        weeklyTotalVisibility: Visibility,
        monthlyTotalVisibility: Visibility,
        yearlyTotalVisibility: Visibility,
        favouritePubsVisibility: Visibility,
        sharedSessionsVisibility: Visibility
    ) {
        self.userId = userId
        self.profileVisibility = profileVisibility
        self.avatarVisibility = avatarVisibility
        self.cityVisibility = cityVisibility
        self.sessionTotalVisibility = sessionTotalVisibility
        self.weeklyTotalVisibility = weeklyTotalVisibility
        self.monthlyTotalVisibility = monthlyTotalVisibility
        self.yearlyTotalVisibility = yearlyTotalVisibility
        self.favouritePubsVisibility = favouritePubsVisibility
        self.sharedSessionsVisibility = sharedSessionsVisibility
    }

    /// Recommended onboarding defaults (master prompt §17.8):
    /// profile → friends, city → off, favourite pubs → off,
    /// totals → visible to accepted friends, recent shared sessions → on.
    public static func recommendedDefault(userId: UUID) -> PrivacySettings {
        PrivacySettings(
            userId: userId,
            profileVisibility: .friends,
            avatarVisibility: .friends,
            cityVisibility: .private,
            sessionTotalVisibility: .friends,
            weeklyTotalVisibility: .friends,
            monthlyTotalVisibility: .friends,
            yearlyTotalVisibility: .friends,
            favouritePubsVisibility: .private,
            sharedSessionsVisibility: .friends
        )
    }

    /// Visibility for a given period's total, so the leaderboard can resolve the
    /// right switch without a big `switch` at each call site.
    public func totalVisibility(for period: LeaderboardPeriod) -> Visibility {
        switch period {
        case .session: return sessionTotalVisibility
        case .week: return weeklyTotalVisibility
        case .month: return monthlyTotalVisibility
        case .year: return yearlyTotalVisibility
        }
    }
}
