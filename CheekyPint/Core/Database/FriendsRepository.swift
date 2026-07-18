import Foundation
import CheekyPintCore

/// Friendships, blocking, reporting, and QR-token resolution — all through the privacy-aware
/// RPCs. The client never reads another user's raw rows directly.
struct FriendsRepository: Sendable {
    let data: SupabaseData

    func resolveToken(_ raw: String) async throws -> FriendPreviewDTO {
        if await DemoWorld.shared.isActive {
            return FriendPreviewDTO(userId: DemoWorld.barnabyID, displayName: "A new mate", avatarPath: nil)
        }
        return try await data.rpc("resolve_friend_token", params: RawTokenParams(pRawToken: raw))
    }

    func sendRequest(to userID: UUID) async throws {
        if await DemoWorld.shared.isActive { return }
        try await data.rpcVoid("send_friend_request", params: AddresseeParams(pAddressee: userID))
    }

    func respond(to friendshipID: UUID, accept: Bool) async throws {
        if await DemoWorld.shared.isActive { return }
        try await data.rpcVoid(
            "respond_to_friend_request", params: RespondParams(pFriendshipId: friendshipID, pAccept: accept))
    }

    func removeFriend(_ userID: UUID) async throws {
        if await DemoWorld.shared.isActive { return }
        try await data.rpcVoid("remove_friend", params: OtherUserParams(pOther: userID))
    }

    func block(_ userID: UUID) async throws {
        if await DemoWorld.shared.isActive { return }
        try await data.rpcVoid("block_user", params: TargetParams(pTarget: userID))
    }

    func unblock(_ userID: UUID) async throws {
        if await DemoWorld.shared.isActive { return }
        try await data.rpcVoid("unblock_user", params: TargetParams(pTarget: userID))
    }

    func report(_ userID: UUID, category: ReportCategory, details: String?) async throws {
        if await DemoWorld.shared.isActive { return }
        try await data.rpcVoid(
            "report_user", params: ReportParams(pTarget: userID, pCategory: category.rawValue, pDetails: details))
    }

    func fetchFriends() async throws -> [FriendDTO] {
        if await DemoWorld.shared.isActive { return await DemoWorld.shared.friends() }
        return try await data.rpc("get_friends", params: EmptyBody())
    }

    func fetchPendingRequests() async throws -> [PendingRequestDTO] {
        if await DemoWorld.shared.isActive { return await DemoWorld.shared.pendingRequests() }
        return try await data.rpc("get_pending_requests", params: EmptyBody())
    }

    func fetchFriendProfile(_ userID: UUID) async throws -> FriendProfileDTO {
        if await DemoWorld.shared.isActive { return await DemoWorld.shared.friendProfile(userID) }
        return try await data.rpc("get_friend_profile", params: FriendParams(pFriend: userID))
    }

    func fetchFavouritePubs(of userID: UUID) async throws -> [FavouritePubDTO] {
        if await DemoWorld.shared.isActive { return await DemoWorld.shared.favouritePubs() }
        return try await data.rpc("get_favourite_pubs", params: UserParams(pUser: userID))
    }

    func fetchBlockedUsers() async throws -> [FriendPreviewDTO] {
        if await DemoWorld.shared.isActive { return [] }
        return try await data.rpc("get_blocked_users", params: EmptyBody())
    }
}
