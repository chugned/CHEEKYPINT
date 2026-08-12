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
struct NudgeParams: Encodable, Sendable { let pRecipientId: UUID }

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

/// One unanswered Nudge, shown to its recipient until they nudge back.
struct NudgeDTO: Decodable, Sendable, Identifiable {
    let nudgeId: UUID
    let senderId: UUID
    let displayName: String
    let avatarPath: String?
    let createdAt: Date
    var id: UUID { nudgeId }
}

// MARK: Feed

/// A cursor into the feed. Both halves travel together: `feed_page` orders by
/// `(created_at, id)` so tied timestamps cannot skip rows, and sending only the timestamp
/// silently reintroduces that bug.
struct FeedCursor: Sendable, Equatable {
    let createdAt: String
    let postID: UUID
}

struct FeedPageParams: Encodable, Sendable {
    let pBefore: String?
    let pBeforeId: UUID?
    let pLimit: Int

    init(cursor: FeedCursor?, limit: Int) {
        self.pBefore = cursor?.createdAt
        self.pBeforeId = cursor?.postID
        self.pLimit = limit
    }

    // Deliberate exception to the "no hand-written CodingKeys" rule, same spirit as
    // `FeedPostDTO`'s: Swift's synthesised `Encodable` conformance calls `encodeIfPresent` for
    // `Optional` properties, which OMITS the key entirely when nil, rather than sending JSON
    // `null`. For every other params struct that is harmless (the RPC's SQL default applies
    // either way). Here it isn't just cosmetic: it is the only way to send an explicit,
    // observable "no cursor" for the first page rather than relying on the key being silently
    // absent, so this stays hand-written even though `.convertToSnakeCase` still does the
    // pFoo -> p_foo renaming for these key names exactly as it does for every synthesised type.
    private enum CodingKeys: String, CodingKey { case pBefore, pBeforeId, pLimit }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pBefore, forKey: .pBefore)
        try container.encode(pBeforeId, forKey: .pBeforeId)
        try container.encode(pLimit, forKey: .pLimit)
    }
}

struct PostIDParams: Encodable, Sendable { let pPostId: UUID }
struct CommentIDParams: Encodable, Sendable { let pCommentId: UUID }

struct CreatePostParams: Encodable, Sendable {
    let pBody: String?
    let pImagePath: String?
    let pPlaceLabel: String?
    let pPubId: UUID?
}

struct CommentsPageParams: Encodable, Sendable {
    let pPostId: UUID
    let pBefore: String?
    let pBeforeId: UUID?
    let pLimit: Int

    // Same explicit-null reasoning as `FeedPageParams.encode(to:)` above: `post_comments_page`
    // has an identical two-part cursor, so the first page's "no cursor" must be just as
    // explicit and not depend on Optional-omission being equivalent to the SQL default.
    private enum CodingKeys: String, CodingKey { case pPostId, pBefore, pBeforeId, pLimit }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pPostId, forKey: .pPostId)
        try container.encode(pBefore, forKey: .pBefore)
        try container.encode(pBeforeId, forKey: .pBeforeId)
        try container.encode(pLimit, forKey: .pLimit)
    }
}

struct AddCommentParams: Encodable, Sendable {
    let pPostId: UUID
    let pBody: String
    let pMentions: [UUID]
}

struct ReportPostParams: Encodable, Sendable {
    let pPostId: UUID
    let pCategory: String
    let pDetails: String?
}

struct ReportCommentParams: Encodable, Sendable {
    let pCommentId: UUID
    let pCategory: String
    let pDetails: String?
}

/// One row of the friends-only feed.
///
/// `createdAtRaw` is deliberately a `String`: it is the cursor's first half and must survive a
/// round trip byte-for-byte. `createdAt` is the parsed form, for display only.
struct FeedPostDTO: Decodable, Sendable, Identifiable {
    let postId: UUID
    let authorId: UUID
    let displayName: String
    let avatarPath: String?
    let body: String?
    let imagePath: String?
    let placeLabel: String?
    let pubId: UUID?
    let createdAtRaw: String
    let cheersCount: Int
    let viewerHasCheered: Bool
    let commentCount: Int

    var id: UUID { postId }
    var createdAt: Date? { SupabaseJSON.parseTimestamp(createdAtRaw) }
    var cursor: FeedCursor { FeedCursor(createdAt: createdAtRaw, postID: postId) }

    // Deliberate exception to the "never write CodingKeys" rule (see JSONCoding.swift and the
    // repo-wide convention): every other property here still relies on `.convertFromSnakeCase`.
    // This single key exists only to route the server's `created_at` into `createdAtRaw` as a
    // `String` instead of letting the decoder's custom date strategy turn it into a `Date` —
    // that would lose the sub-second precision the `(created_at, id)` cursor depends on.
    private enum CodingKeys: String, CodingKey {
        case postId, authorId, displayName, avatarPath, body, imagePath
        case placeLabel, pubId, cheersCount, viewerHasCheered, commentCount
        case createdAtRaw = "createdAt"
    }
}

struct PostCommentDTO: Decodable, Sendable, Identifiable {
    let commentId: UUID
    let authorId: UUID
    let displayName: String
    let avatarPath: String?
    let body: String
    let createdAtRaw: String
    let mentionedUserIds: [UUID]

    var id: UUID { commentId }
    var createdAt: Date? { SupabaseJSON.parseTimestamp(createdAtRaw) }
    var cursor: FeedCursor { FeedCursor(createdAt: createdAtRaw, postID: commentId) }

    // Same deliberate exception as `FeedPostDTO.CodingKeys` — see the comment there.
    private enum CodingKeys: String, CodingKey {
        case commentId, authorId, displayName, avatarPath, body, mentionedUserIds
        case createdAtRaw = "createdAt"
    }
}

struct ToggleCheersDTO: Decodable, Sendable {
    let cheered: Bool
    let cheersCount: Int
}

struct CreatedPostDTO: Decodable, Sendable { let postId: UUID }
struct CreatedCommentDTO: Decodable, Sendable { let commentId: UUID }

/// Shared ack shape for the moderation-report RPCs (`report_user`, `report_post`,
/// `report_comment`), which all return `jsonb_build_object('report_id', ..., 'status', ...)`.
struct ReportAckDTO: Decodable, Sendable {
    let reportId: UUID
    let status: String
}
