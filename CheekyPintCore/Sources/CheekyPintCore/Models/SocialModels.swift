import Foundation

/// A directed friendship row. `requester` sent the request to `addressee`.
/// A relationship is only mutual/visible when `status == .accepted`.
public struct Friendship: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var requesterId: UUID
    public var addresseeId: UUID
    public var status: FriendshipStatus
    public var requestedAt: Date
    public var respondedAt: Date?
    public var updatedAt: Date

    public init(
        id: UUID,
        requesterId: UUID,
        addresseeId: UUID,
        status: FriendshipStatus,
        requestedAt: Date = Date(),
        respondedAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.requesterId = requesterId
        self.addresseeId = addresseeId
        self.status = status
        self.requestedAt = requestedAt
        self.respondedAt = respondedAt
        self.updatedAt = updatedAt
    }

    public func involves(_ userId: UUID) -> Bool {
        requesterId == userId || addresseeId == userId
    }

    /// The other party relative to `userId`, or `nil` if the row doesn't involve them.
    public func counterpart(of userId: UUID) -> UUID? {
        if requesterId == userId { return addresseeId }
        if addresseeId == userId { return requesterId }
        return nil
    }

    public var isAccepted: Bool { status == .accepted }
}

/// A block. Directed, but its effect is symmetric on visibility: while a block exists,
/// neither party sees the other anywhere (master prompt §9, §14).
public struct Block: Codable, Sendable, Hashable {
    public var blockerId: UUID
    public var blockedId: UUID
    public var createdAt: Date

    public init(blockerId: UUID, blockedId: UUID, createdAt: Date = Date()) {
        self.blockerId = blockerId
        self.blockedId = blockedId
        self.createdAt = createdAt
    }

    public func involves(_ userId: UUID) -> Bool {
        blockerId == userId || blockedId == userId
    }
}

/// A moderation report against a user, queued for admin review.
public struct Report: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var reporterId: UUID
    public var reportedUserId: UUID
    public var category: ReportCategory
    public var details: String?
    public var status: String
    public var createdAt: Date
    public var reviewedAt: Date?

    public init(
        id: UUID,
        reporterId: UUID,
        reportedUserId: UUID,
        category: ReportCategory,
        details: String? = nil,
        status: String = "open",
        createdAt: Date = Date(),
        reviewedAt: Date? = nil
    ) {
        self.id = id
        self.reporterId = reporterId
        self.reportedUserId = reportedUserId
        self.category = category
        self.details = details
        self.status = status
        self.createdAt = createdAt
        self.reviewedAt = reviewedAt
    }
}

/// A "clink" — a decorative social memory between session participants.
/// It records that friends were together; it NEVER changes any drink total (§12).
public struct Clink: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var sessionId: UUID
    public var createdBy: UUID
    public var createdAt: Date

    public init(id: UUID, sessionId: UUID, createdBy: UUID, createdAt: Date = Date()) {
        self.id = id
        self.sessionId = sessionId
        self.createdBy = createdBy
        self.createdAt = createdAt
    }
}
