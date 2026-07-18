import Foundation

/// Turns a `LeaderboardPeriod` into a concrete `[start, end)` window for a specific user.
///
/// All the hard parts — first weekday, calendar month lengths, leap years, daylight-saving
/// transitions, and time-zone offset — are delegated to `Calendar.dateInterval(of:for:)`,
/// which is the correct, battle-tested Foundation primitive. We never do manual
/// `addingTimeInterval(7 * 86_400)` arithmetic, which breaks across DST and month ends.
public struct PeriodCalculator: Sendable {
    public let calendar: Calendar

    /// - Parameter calendar: A fully-configured calendar — typically `Profile.resolvedCalendar`,
    ///   which carries the user's locale (first weekday) and time zone.
    public init(calendar: Calendar) {
        self.calendar = calendar
    }

    /// Convenience initialiser from a profile.
    public init(profile: Profile) {
        self.calendar = profile.resolvedCalendar
    }

    /// Resolve a concrete window.
    ///
    /// - Parameters:
    ///   - period: which window to compute.
    ///   - date: the reference instant the window should contain (usually "now").
    ///   - session: required for `.session`; the window is the session's
    ///     `[startedAt, endedAt ?? now)`.
    ///   - now: upper bound for an active session; defaults to `date`.
    /// - Returns: the window, or `nil` for `.session` when no session is supplied.
    public func period(
        for period: LeaderboardPeriod,
        containing date: Date,
        session: PubSession? = nil,
        now: Date? = nil
    ) -> DatePeriod? {
        switch period {
        case .week:  return interval(of: .weekOfYear, containing: date)
        case .month: return interval(of: .month, containing: date)
        case .year:  return interval(of: .year, containing: date)
        case .session:
            guard let session else { return nil }
            let upper = session.effectiveEnd(now: now ?? date)
            // Guard against a session whose stored end precedes its start.
            let end = max(upper, session.startedAt)
            return DatePeriod(start: session.startedAt, end: end)
        }
    }

    /// The calendar-aware window of `component` that contains `date`.
    public func interval(of component: Calendar.Component, containing date: Date) -> DatePeriod? {
        guard let interval = calendar.dateInterval(of: component, for: date) else { return nil }
        return DatePeriod(start: interval.start, end: interval.end)
    }

    // Named helpers, handy at call sites and in tests.

    public func week(containing date: Date) -> DatePeriod? {
        interval(of: .weekOfYear, containing: date)
    }

    public func month(containing date: Date) -> DatePeriod? {
        interval(of: .month, containing: date)
    }

    public func year(containing date: Date) -> DatePeriod? {
        interval(of: .year, containing: date)
    }
}
