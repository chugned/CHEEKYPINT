import Foundation
import CheekyPintCore

// Parameter structs for the SECURITY DEFINER RPCs. Property names are camelCase versions of
// the SQL argument names; `SupabaseJSON.encoder` converts them to snake_case (pFooBar →
// p_foo_bar). Optional params are omitted when nil, so the SQL defaults apply.

struct CreatePintParams: Encodable, Sendable {
    let pIdempotencyKey: String
    let pOccurredAt: Date
    let pServingType: String
    let pVolumeMl: Double?
    let pAlcoholFree: Bool
    let pPubId: UUID?
    let pSessionId: UUID?
    let pPrivateNote: String?
    let pSource: String
}

struct EntryIDParams: Encodable, Sendable { let pEntryId: UUID }
struct RawTokenParams: Encodable, Sendable { let pRawToken: String }
struct AddresseeParams: Encodable, Sendable { let pAddressee: UUID }
struct RespondParams: Encodable, Sendable { let pFriendshipId: UUID; let pAccept: Bool }
struct OtherUserParams: Encodable, Sendable { let pOther: UUID }
struct TargetParams: Encodable, Sendable { let pTarget: UUID }
struct ReportParams: Encodable, Sendable { let pTarget: UUID; let pCategory: String; let pDetails: String? }
struct FriendParams: Encodable, Sendable { let pFriend: UUID }
struct UserParams: Encodable, Sendable { let pUser: UUID }
struct SessionParams: Encodable, Sendable { let pSessionId: UUID }
struct CreateSessionParams: Encodable, Sendable { let pPubId: UUID?; let pName: String? }
struct ClinkParams: Encodable, Sendable { let pSessionId: UUID; let pParticipants: [UUID] }

struct LeaderboardParams: Encodable, Sendable {
    let pPeriodStart: Date
    let pPeriodEnd: Date
    let pPeriodKind: String
    let pSessionId: UUID?
}

// Response DTOs for RPCs that return rows/objects.

struct LeaderboardRowDTO: Decodable, Sendable {
    let userId: UUID
    let displayName: String
    let avatarPath: String?
    let recordedCount: Int
    let isPrivate: Bool
    let isCurrentUser: Bool
}

struct FriendDTO: Decodable, Sendable, Identifiable {
    let userId: UUID
    let displayName: String
    let avatarPath: String?
    let city: String?
    let friendSince: Date?
    var id: UUID { userId }
}

struct PendingRequestDTO: Decodable, Sendable, Identifiable {
    let friendshipId: UUID
    let userId: UUID
    let displayName: String
    let avatarPath: String?
    let requestedAt: Date
    var id: UUID { friendshipId }
}

struct FriendPreviewDTO: Decodable, Sendable {
    let userId: UUID
    let displayName: String
    let avatarPath: String?
}

struct FriendProfileDTO: Decodable, Sendable {
    let userId: UUID
    let displayName: String
    let username: String?
    let bio: String?
    let avatarPath: String?
    let city: String?
    let countryCode: String?
    let friendSince: Date?
}

struct FavouritePubDTO: Decodable, Sendable, Identifiable {
    let pubId: UUID
    let name: String
    let city: String?
    let visitCount: Int
    let lastVisit: Date?
    let sharedVisitCount: Int?
    var id: UUID { pubId }
}

struct CreatedSessionDTO: Decodable, Sendable {
    let sessionId: UUID
    let joinToken: String
    let startedAt: Date
    let status: String
}
