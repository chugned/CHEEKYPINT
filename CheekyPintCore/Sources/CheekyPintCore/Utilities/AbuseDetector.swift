import Foundation

/// Why a new entry was flagged as implausibly frequent. Used only as audit metadata —
/// it is never surfaced to the user as an accusation (master prompt §16).
public enum AbuseFlag: Sendable, Equatable {
    /// Logged closer to the previous entry than is physically plausible.
    case tooSoonAfterPrevious(interval: TimeInterval)
    /// More entries in the trailing hour than the configured ceiling.
    case tooManyPerHour(count: Int)
}

/// Lightweight, non-punitive frequency check. CheekyPint is a casual diary, not a certified
/// measurement device, so this only *flags* suspicious cadence for audit metadata and
/// welfare handling. It never blocks logging outright or publicly accuses anyone.
///
/// The authoritative version of this check also runs server-side; the client copy gives
/// immediate, offline-capable feedback.
public struct AbuseDetector: Sendable {
    public let minInterval: TimeInterval
    public let maxPerHour: Int

    /// - Parameters:
    ///   - minInterval: minimum plausible gap between two drinks. Default 60 seconds.
    ///   - maxPerHour: implausible number of entries within a trailing hour. Default 12.
    public init(minInterval: TimeInterval = 60, maxPerHour: Int = 12) {
        self.minInterval = minInterval
        self.maxPerHour = maxPerHour
    }

    /// Returns any flags for a new entry at `newDate`, given the user's recent entry dates.
    public func flags(forEntryAt newDate: Date, recentEntryDates: [Date]) -> [AbuseFlag] {
        var flags: [AbuseFlag] = []

        if let mostRecentBefore = recentEntryDates.filter({ $0 <= newDate }).max() {
            let interval = newDate.timeIntervalSince(mostRecentBefore)
            if interval >= 0 && interval < minInterval {
                flags.append(.tooSoonAfterPrevious(interval: interval))
            }
        }

        let hourAgo = newDate.addingTimeInterval(-3600)
        let inLastHour = recentEntryDates.filter { $0 > hourAgo && $0 <= newDate }.count + 1
        if inLastHour > maxPerHour {
            flags.append(.tooManyPerHour(count: inLastHour))
        }

        return flags
    }

    public func isImplausible(forEntryAt newDate: Date, recentEntryDates: [Date]) -> Bool {
        !flags(forEntryAt: newDate, recentEntryDates: recentEntryDates).isEmpty
    }
}
