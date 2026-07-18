import Foundation

/// Field-level visibility. The MVP deliberately has NO `public` case — the most a
/// value can be shared is with accepted friends (master prompt §9, §13).
public enum Visibility: String, Codable, CaseIterable, Sendable {
    case `private`
    case friends
}

/// Lifecycle of a friendship row. A friendship is only "real" when `accepted`.
public enum FriendshipStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case accepted
    case declined
    case removed
}

/// State of a temporary pub gathering.
public enum SessionStatus: String, Codable, CaseIterable, Sendable {
    case active
    case ended
}

/// A member's role within a pub session.
public enum SessionMemberRole: String, Codable, CaseIterable, Sendable {
    case host
    case member
}

/// Where a pub record originated.
public enum PubSource: String, Codable, CaseIterable, Sendable {
    case mapkit
    case userSuggested = "user_suggested"
}

/// Where a pint entry was created (used for audit + anti-abuse, never shown as a boast).
public enum EntrySource: String, Codable, CaseIterable, Sendable {
    case manual
    case quickLog = "quick_log"
    case offlineQueue = "offline_queue"
}

/// Report categories for user-generated-content moderation.
public enum ReportCategory: String, Codable, CaseIterable, Sendable {
    case inappropriateProfileImage = "inappropriate_profile_image"
    case inappropriateText = "inappropriate_text"
    case harassment
    case impersonation
    case underageConcern = "underage_concern"
    case other

    public var displayName: String {
        switch self {
        case .inappropriateProfileImage: return "Inappropriate profile image"
        case .inappropriateText: return "Inappropriate text"
        case .harassment: return "Harassment"
        case .impersonation: return "Impersonation"
        case .underageConcern: return "Underage concern"
        case .other: return "Something else"
        }
    }
}

/// The relationship the *viewer* has to a target user. Every read of another user's
/// data resolves through this, and ``Relationship/blocked`` overrides everything else.
public enum Relationship: Sendable, Equatable {
    /// The viewer is looking at their own data.
    case current
    /// Accepted, mutual friendship.
    case friend
    /// A pending request exists but is not yet accepted — minimum safe preview only.
    case pendingRequest
    /// No relationship.
    case stranger
    /// Either party has blocked the other. Always wins.
    case blocked
}
