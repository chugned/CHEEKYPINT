import Foundation

/// The explicit, documented rule for turning entries into a leaderboard number
/// (master prompt §7, §13). The MVP counts **entries** ("pints recorded"), while the
/// real serving size is preserved in the database so a standardised-servings basis can
/// be switched on later without a data migration.
public struct PintCountingRule: Sendable, Equatable {
    public enum Basis: Sendable, Equatable {
        /// Each qualifying entry counts as one "pint recorded". This is the MVP default.
        case entries
        /// Sum of volume divided by `referenceMl`, rounded for display by the caller.
        case standardServings(referenceMl: Double)
    }

    public var basis: Basis
    /// When false (default), alcohol-free entries are excluded from the total.
    /// They still appear in the personal diary, clearly labelled (§15).
    public var includeAlcoholFree: Bool

    public init(basis: Basis, includeAlcoholFree: Bool) {
        self.basis = basis
        self.includeAlcoholFree = includeAlcoholFree
    }

    /// MVP leaderboard rule: entry-based, alcohol-free excluded.
    public static let `default` = PintCountingRule(basis: .entries, includeAlcoholFree: false)

    /// A separate "drinks logged" style rule that includes alcohol-free drinks.
    public static let allDrinks = PintCountingRule(basis: .entries, includeAlcoholFree: true)

    /// Standardised to UK pints — available for a future, opt-in display mode.
    public static let ukPintEquivalent = PintCountingRule(
        basis: .standardServings(referenceMl: 568.26),
        includeAlcoholFree: false
    )

    /// Whether a given entry qualifies under this rule (ignoring the time window,
    /// which the counter applies separately).
    public func qualifies(_ entry: PintEntry) -> Bool {
        guard entry.isActive else { return false }
        if !includeAlcoholFree && entry.alcoholFree { return false }
        return true
    }
}
