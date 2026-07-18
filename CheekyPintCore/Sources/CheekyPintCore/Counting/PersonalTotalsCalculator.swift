import Foundation

/// The four home-screen totals for the current user. `session` is `nil` when there is no
/// active pub session (the home screen then shows "No active pub session", §7).
public struct PersonalTotals: Sendable, Equatable {
    public var session: PintTotal?
    public var week: PintTotal
    public var month: PintTotal
    public var year: PintTotal

    public init(session: PintTotal?, week: PintTotal, month: PintTotal, year: PintTotal) {
        self.session = session
        self.week = week
        self.month = month
        self.year = year
    }

    public subscript(period: LeaderboardPeriod) -> PintTotal? {
        switch period {
        case .session: return session
        case .week: return week
        case .month: return month
        case .year: return year
        }
    }
}

/// Computes all of a single user's period totals in one pass-friendly call. Combines a
/// `PeriodCalculator` (windows) with a `PintCounter` (aggregation) so the Home view model
/// has one dependency instead of wiring both together itself.
public struct PersonalTotalsCalculator: Sendable {
    public let calculator: PeriodCalculator
    public let counter: PintCounter

    public init(calendar: Calendar, rule: PintCountingRule = .default) {
        self.calculator = PeriodCalculator(calendar: calendar)
        self.counter = PintCounter(rule: rule)
    }

    public init(profile: Profile, rule: PintCountingRule = .default) {
        self.init(calendar: profile.resolvedCalendar, rule: rule)
    }

    public func totals(
        entries: [PintEntry],
        now: Date = Date(),
        session: PubSession? = nil
    ) -> PersonalTotals {
        let week = counter.total(of: entries, in: calculator.week(containing: now))
        let month = counter.total(of: entries, in: calculator.month(containing: now))
        let year = counter.total(of: entries, in: calculator.year(containing: now))

        let sessionTotal: PintTotal? = session.map { activeSession in
            let window = calculator.period(for: .session, containing: now, session: activeSession, now: now)
            return counter.total(of: entries, in: window)
        }

        return PersonalTotals(session: sessionTotal, week: week, month: month, year: year)
    }
}
