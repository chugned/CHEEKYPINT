import Foundation

/// The time windows the app aggregates over. `session` is "Now" on the home screen —
/// the currently active pub session, *not* the current instant or current day (master
/// prompt §7). The other three are calendar-aware windows around a reference date.
public enum LeaderboardPeriod: String, Codable, CaseIterable, Sendable, Identifiable {
    case session
    case week
    case month
    case year

    public var id: String { rawValue }

    /// Compact label for the home-screen segmented control (§7).
    public var shortLabel: String {
        switch self {
        case .session: return "Now"
        case .week: return "Week"
        case .month: return "Month"
        case .year: return "Year"
        }
    }

    /// Full title for the leaderboard header (§9).
    public var leaderboardTitle: String {
        switch self {
        case .session: return "Current session"
        case .week: return "This week"
        case .month: return "This month"
        case .year: return "This year"
        }
    }
}
