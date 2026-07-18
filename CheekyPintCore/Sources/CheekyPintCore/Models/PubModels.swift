import Foundation

/// A pub — a public business location. Coordinates are public; a *user's* visit history
/// to a pub is private user data (master prompt §11). Maps to the `pubs` table.
public struct Pub: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var externalSource: PubSource?
    public var externalIdentifier: String?
    public var name: String
    public var formattedAddress: String?
    public var city: String?
    public var countryCode: String?
    public var latitude: Double
    public var longitude: Double
    public var createdBy: UUID?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        externalSource: PubSource? = nil,
        externalIdentifier: String? = nil,
        name: String,
        formattedAddress: String? = nil,
        city: String? = nil,
        countryCode: String? = nil,
        latitude: Double,
        longitude: Double,
        createdBy: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.externalSource = externalSource
        self.externalIdentifier = externalIdentifier
        self.name = name
        self.formattedAddress = formattedAddress
        self.city = city
        self.countryCode = countryCode
        self.latitude = latitude
        self.longitude = longitude
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A temporary gathering at a pub. The raw join token is never sent to clients —
/// only its hash lives server-side. Maps to `pub_sessions`.
public struct PubSession: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var pubId: UUID?
    public var hostUserId: UUID
    public var name: String?
    public var status: SessionStatus
    public var startedAt: Date
    public var endedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        pubId: UUID? = nil,
        hostUserId: UUID,
        name: String? = nil,
        status: SessionStatus = .active,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.pubId = pubId
        self.hostUserId = hostUserId
        self.name = name
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isActive: Bool { status == .active && endedAt == nil }

    /// The end bound to use for "current session" totals: the real end, or `now`
    /// while the session is still active (master prompt §15).
    public func effectiveEnd(now: Date) -> Date { endedAt ?? now }
}

/// Membership of a user in a pub session. A user must *explicitly* join —
/// participation is never inferred from proximity (master prompt §12).
public struct SessionMember: Codable, Sendable, Hashable {
    public var sessionId: UUID
    public var userId: UUID
    public var role: SessionMemberRole
    public var joinedAt: Date
    public var leftAt: Date?

    public init(
        sessionId: UUID,
        userId: UUID,
        role: SessionMemberRole = .member,
        joinedAt: Date = Date(),
        leftAt: Date? = nil
    ) {
        self.sessionId = sessionId
        self.userId = userId
        self.role = role
        self.joinedAt = joinedAt
        self.leftAt = leftAt
    }

    public var isActive: Bool { leftAt == nil }
}
