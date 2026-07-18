import Foundation

/// Input to the leaderboard builder: one accepted friend (or the current user) with
/// their already-privacy-resolved total. A `nil` total means the friend has hidden this
/// period's total and should appear as "Private" (master prompt §9).
public struct LeaderboardParticipant: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var displayName: String
    public var avatarPath: String?
    public var isCurrentUser: Bool
    public var total: PintTotal?

    public init(
        id: UUID,
        displayName: String,
        avatarPath: String? = nil,
        isCurrentUser: Bool = false,
        total: PintTotal?
    ) {
        self.id = id
        self.displayName = displayName
        self.avatarPath = avatarPath
        self.isCurrentUser = isCurrentUser
        self.total = total
    }
}

/// A rendered leaderboard row. `rank` and `value` are `nil` for private participants,
/// which are shown with a neutral "Private" marker rather than a fabricated zero.
public struct LeaderboardRow: Sendable, Equatable, Identifiable {
    public let id: UUID
    public var rank: Int?
    public var displayName: String
    public var avatarPath: String?
    public var isCurrentUser: Bool
    public var value: Double?
    public var isPrivate: Bool

    public init(
        id: UUID,
        rank: Int?,
        displayName: String,
        avatarPath: String?,
        isCurrentUser: Bool,
        value: Double?,
        isPrivate: Bool
    ) {
        self.id = id
        self.rank = rank
        self.displayName = displayName
        self.avatarPath = avatarPath
        self.isCurrentUser = isCurrentUser
        self.value = value
        self.isPrivate = isPrivate
    }
}
