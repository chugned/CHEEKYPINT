import Foundation

/// The result of aggregating entries: both the MVP display number and the
/// standardised-servings figure, so callers can present either without recounting.
public struct PintTotal: Sendable, Equatable, Hashable {
    /// Number of qualifying entries — the "pints recorded" shown in the MVP.
    public var recordedCount: Int
    /// Sum of known volumes expressed in reference servings (UK pints by default).
    /// Entries with an unknown custom volume contribute 0 here but still increment
    /// `recordedCount`.
    public var standardServings: Double

    public init(recordedCount: Int, standardServings: Double) {
        self.recordedCount = recordedCount
        self.standardServings = standardServings
    }

    public static let zero = PintTotal(recordedCount: 0, standardServings: 0)

    /// The single number the leaderboard/home surfaces expose under `rule`.
    public func displayValue(for rule: PintCountingRule) -> Double {
        switch rule.basis {
        case .entries: return Double(recordedCount)
        case .standardServings: return standardServings
        }
    }
}

/// Aggregates `PintEntry` values into totals, applying the counting rule and time window.
/// Pure and deterministic — no clock, no I/O — so it is exhaustively unit-tested.
public struct PintCounter: Sendable {
    public let rule: PintCountingRule

    public init(rule: PintCountingRule = .default) {
        self.rule = rule
    }

    /// Total for the entries whose `occurredAt` falls inside `period` and that qualify
    /// under the rule. Pass `period == nil` (e.g. no active session) to get `.zero`.
    public func total(of entries: [PintEntry], in period: DatePeriod?) -> PintTotal {
        guard let period else { return .zero }
        let referenceMl: Double = {
            if case let .standardServings(ml) = rule.basis { return ml }
            return 568.26
        }()

        var count = 0
        var servings = 0.0
        for entry in entries where rule.qualifies(entry) && period.contains(entry.occurredAt) {
            count += 1
            if let ml = entry.effectiveVolumeMl {
                servings += ml / referenceMl
            }
        }
        return PintTotal(recordedCount: count, standardServings: servings)
    }

    /// Convenience: the raw display number for a period.
    public func displayValue(of entries: [PintEntry], in period: DatePeriod?) -> Double {
        total(of: entries, in: period).displayValue(for: rule)
    }
}
