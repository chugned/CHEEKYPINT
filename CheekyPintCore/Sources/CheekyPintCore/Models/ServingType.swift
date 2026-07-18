import Foundation

/// The physical size of a recorded drink. This is stored per `PintEntry` so the
/// real serving is always preserved in the database, even though the MVP leaderboard
/// counts *entries* rather than standardised volume (see ``PintCountingRule``).
///
/// `alcoholFree` is intentionally NOT a case here — being alcohol-free is an
/// independent flag on a ``PintEntry`` (a half pint can be alcohol-free), which
/// matches the `serving_type` + `alcohol_free` columns in the database.
public enum ServingType: String, Codable, CaseIterable, Sendable, Hashable {
    case halfPint = "half_pint"
    case pint
    case ml330 = "ml_330"
    case ml500 = "ml_500"
    case custom

    /// Nominal volume in millilitres. `nil` for ``custom``, where the entry carries
    /// its own `volumeMl`. UK imperial measures are used for pints.
    public var nominalVolumeMl: Double? {
        switch self {
        case .halfPint: return 284.13   // ½ UK imperial pint
        case .pint: return 568.26       // 1 UK imperial pint
        case .ml330: return 330
        case .ml500: return 500
        case .custom: return nil
        }
    }

    /// Human-facing short label. Kept here (not in the UI layer) so labels stay
    /// consistent across app, analytics bucketing, and tests.
    public var displayName: String {
        switch self {
        case .halfPint: return "Half pint"
        case .pint: return "Pint"
        case .ml330: return "330 ml"
        case .ml500: return "500 ml"
        case .custom: return "Custom"
        }
    }

    /// The default serving offered in the confirmation sheet.
    public static let `default`: ServingType = .pint
}
