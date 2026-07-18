import Foundation

/// A half-open time window `[start, end)`. Half-open avoids the classic
/// double-counting bug where an entry exactly on a boundary lands in two periods.
public struct DatePeriod: Sendable, Equatable, Hashable {
    /// Inclusive lower bound.
    public let start: Date
    /// Exclusive upper bound.
    public let end: Date

    public init(start: Date, end: Date) {
        precondition(end >= start, "DatePeriod end must not precede start")
        self.start = start
        self.end = end
    }

    /// True when `date` is in `[start, end)`.
    public func contains(_ date: Date) -> Bool {
        date >= start && date < end
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}
