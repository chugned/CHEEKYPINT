import Foundation
import CheekyPintCore

/// The friends-only feed. Every read and write goes through a `security definer` RPC that
/// re-derives friendship and block state per call — the client never reads post rows directly,
/// and holding a post id is never sufficient authority.
struct FeedRepository: Sendable {
    let data: SupabaseData

    // MARK: Reading

    func page(before cursor: FeedCursor?, limit: Int = 20) async throws -> [FeedPostDTO] {
        if await DemoWorld.shared.isActive { return await DemoWorld.shared.feedPage(before: cursor, limit: limit) }
        return try await data.rpc("feed_page", params: FeedPageParams(cursor: cursor, limit: limit))
    }

    func comments(postID: UUID, before cursor: FeedCursor?, limit: Int = 30) async throws -> [PostCommentDTO] {
        if await DemoWorld.shared.isActive { return await DemoWorld.shared.comments(postID: postID) }
        return try await data.rpc("post_comments_page", params: CommentsPageParams(
            pPostId: postID, pBefore: cursor?.createdAt, pBeforeId: cursor?.postID, pLimit: limit))
    }

    // MARK: Writing

    func toggleCheers(postID: UUID) async throws -> ToggleCheersDTO {
        if await DemoWorld.shared.isActive { return await DemoWorld.shared.toggleCheers(postID: postID) }
        return try await data.rpc("toggle_post_cheers", params: PostIDParams(pPostId: postID))
    }

    @discardableResult
    func createPost(body: String?, imagePath: String?, placeLabel: String?, pubID: UUID?) async throws -> UUID {
        if await DemoWorld.shared.isActive {
            return await DemoWorld.shared.createPost(body: body, imagePath: imagePath,
                                                      placeLabel: placeLabel, pubID: pubID)
        }
        let created: CreatedPostDTO = try await data.rpc("create_post", params: CreatePostParams(
            pBody: body, pImagePath: imagePath, pPlaceLabel: placeLabel, pPubId: pubID))
        return created.postId
    }

    func deletePost(_ postID: UUID) async throws {
        if await DemoWorld.shared.isActive { await DemoWorld.shared.deletePost(postID); return }
        try await data.rpcVoid("delete_post", params: PostIDParams(pPostId: postID))
    }

    @discardableResult
    func addComment(postID: UUID, body: String, mentions: [UUID]) async throws -> UUID {
        if await DemoWorld.shared.isActive {
            return await DemoWorld.shared.addComment(postID: postID, body: body, mentions: mentions)
        }
        let created: CreatedCommentDTO = try await data.rpc("add_comment", params: AddCommentParams(
            pPostId: postID, pBody: body, pMentions: mentions))
        return created.commentId
    }

    func deleteComment(_ commentID: UUID) async throws {
        if await DemoWorld.shared.isActive { await DemoWorld.shared.deleteComment(commentID); return }
        try await data.rpcVoid("delete_comment", params: CommentIDParams(pCommentId: commentID))
    }

    // MARK: Moderation and data rights

    func reportPost(_ postID: UUID, category: ReportCategory, details: String?) async throws {
        if await DemoWorld.shared.isActive { return }
        _ = try await data.rpc("report_post", params: ReportPostParams(
            pPostId: postID, pCategory: category.rawValue, pDetails: details)) as ReportAckDTO
    }

    func reportComment(_ commentID: UUID, category: ReportCategory, details: String?) async throws {
        if await DemoWorld.shared.isActive { return }
        _ = try await data.rpc("report_comment", params: ReportCommentParams(
            pCommentId: commentID, pCategory: category.rawValue, pDetails: details)) as ReportAckDTO
    }

    /// DSGVO Art. 15/20 self-service export. Returned as raw bytes so the caller can hand the
    /// user the exact document the server produced, without a lossy re-encode.
    func exportMyData() async throws -> Data {
        if await DemoWorld.shared.isActive { return Data("{\"demo\":true}".utf8) }
        return try await data.rpcRaw("export_my_data")
    }
}
