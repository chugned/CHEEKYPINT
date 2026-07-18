import Foundation

/// A field of another user's profile that visibility rules gate.
public enum ProfileField: Sendable, Equatable, Hashable {
    case displayName
    case avatar
    case city
    case bio
    case favouritePubs
    case sharedSessions
    case total(LeaderboardPeriod)

    /// Totals get special treatment: when hidden they show as "Private" rather than
    /// being silently reported as zero (master prompt §9).
    public var isTotal: Bool {
        if case .total = self { return true }
        return false
    }
}

/// The outcome of a visibility check.
public enum VisibilityDecision: Sendable, Equatable {
    /// Show the real value.
    case visible
    /// Omit entirely (field simply doesn't appear).
    case hidden
    /// Show a neutral "Private" placeholder instead of a value. Used for hidden totals
    /// so a private friend isn't misrepresented as having a zero total.
    case privatePlaceholder

    public var showsValue: Bool { self == .visible }
}

/// Central authority for "can this viewer see this field of that user?".
///
/// This mirrors — and must stay in lockstep with — the server-side RLS policies and
/// `SECURITY DEFINER` functions. The client uses it to avoid *requesting* data it can't
/// show and to render placeholders; the server is the true gatekeeper. The single most
/// important invariant: **a block overrides every other rule.**
public struct VisibilityResolver: Sendable {
    public init() {}

    /// Whether the viewer may open the target's full profile at all.
    public func canViewProfile(relationship: Relationship, profileVisibility: Visibility) -> Bool {
        switch relationship {
        case .blocked: return false
        case .current: return true
        case .friend: return profileVisibility == .friends
        case .pendingRequest, .stranger: return false
        }
    }

    /// The decision for a specific field.
    public func decision(
        for field: ProfileField,
        relationship: Relationship,
        settings: PrivacySettings
    ) -> VisibilityDecision {
        switch relationship {
        case .blocked:
            // A blocked user must never appear on any surface.
            return .hidden

        case .current:
            // You always see your own data.
            return .visible

        case .pendingRequest:
            // Minimum safe preview only: name + avatar, nothing else (§8).
            switch field {
            case .displayName, .avatar: return .visible
            default: return .hidden
            }

        case .stranger:
            return .hidden

        case .friend:
            let fieldVisibility = visibility(of: field, in: settings)
            if fieldVisibility == .friends {
                return .visible
            }
            // Hidden-to-friends: totals degrade to a placeholder, everything else vanishes.
            return field.isTotal ? .privatePlaceholder : .hidden
        }
    }

    /// The configured visibility for a field.
    public func visibility(of field: ProfileField, in settings: PrivacySettings) -> Visibility {
        switch field {
        case .displayName: return settings.profileVisibility
        case .avatar: return settings.avatarVisibility
        case .city: return settings.cityVisibility
        case .bio: return settings.profileVisibility
        case .favouritePubs: return settings.favouritePubsVisibility
        case .sharedSessions: return settings.sharedSessionsVisibility
        case let .total(period): return settings.totalVisibility(for: period)
        }
    }
}
