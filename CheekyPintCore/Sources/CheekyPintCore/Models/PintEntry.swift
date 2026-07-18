import Foundation

/// One drink recorded by a user — the atomic unit of the diary.
/// Maps to the `pint_entries` table.
public struct PintEntry: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let userId: UUID
    public var pubId: UUID?
    public var sessionId: UUID?
    /// The moment the drink happened. User-adjustable, defaults to "now" in the sheet.
    /// The server also stamps `createdAt` independently — never trust the device clock
    /// as the sole authority (master prompt §15).
    public var occurredAt: Date
    public var servingType: ServingType
    /// Required when `servingType == .custom`; ignored otherwise.
    public var volumeMl: Double?
    public var alcoholFree: Bool
    public var privateNote: String?
    public var source: EntrySource
    /// Client-generated; unique per user. Guards against duplicate submissions on retry.
    public var idempotencyKey: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Non-nil once undone/soft-deleted. Soft-deleted entries never count (§15).
    public var deletedAt: Date?

    public init(
        id: UUID,
        userId: UUID,
        pubId: UUID? = nil,
        sessionId: UUID? = nil,
        occurredAt: Date,
        servingType: ServingType = .default,
        volumeMl: Double? = nil,
        alcoholFree: Bool = false,
        privateNote: String? = nil,
        source: EntrySource = .manual,
        idempotencyKey: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.userId = userId
        self.pubId = pubId
        self.sessionId = sessionId
        self.occurredAt = occurredAt
        self.servingType = servingType
        self.volumeMl = volumeMl
        self.alcoholFree = alcoholFree
        self.privateNote = privateNote
        self.source = source
        self.idempotencyKey = idempotencyKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    /// Whether this entry is currently live (not undone/soft-deleted).
    public var isActive: Bool { deletedAt == nil }

    /// The best-known volume in millilitres: the nominal serving volume, or the
    /// custom `volumeMl` for custom servings. `nil` only if a custom entry is missing
    /// its volume (which validation should prevent).
    public var effectiveVolumeMl: Double? {
        servingType.nominalVolumeMl ?? volumeMl
    }

    /// Counts toward alcohol-related friend totals: active and not alcohol-free (§15).
    public var countsTowardAlcoholTotals: Bool {
        isActive && !alcoholFree
    }
}
