import Foundation
import CheekyPintCore

/// The friends-only feed. Every read and write goes through a `security definer` RPC that
/// re-derives friendship and block state per call — the client never reads post rows directly,
/// and holding a post id is never sufficient authority.
struct FeedRepository: Sendable {
    let data: SupabaseData

    // MARK: Reading

    func page(before cursor: FeedCursor?, limit: Int = 20) async throws -> [FeedPostDTO] {
        #if DEBUG
        // See `DebugFaultInjector`'s doc. `.initial`/`.loadMore` are two separately-failable
        // operations, keyed by whether the caller has a cursor yet, so a UI test can let the
        // first page succeed and only fail the paginated call (or vice versa).
        try DebugFaultInjector.throwIfFaulted(
            cursor == nil ? DebugFaultInjector.Operation.feedPageInitial : DebugFaultInjector.Operation.feedPageLoadMore)
        if cursor == nil, DebugFaultInjector.isForcedEmpty(DebugFaultInjector.Operation.feedPageInitial) { return [] }
        #endif
        if await DemoWorld.shared.isActive { return await DemoWorld.shared.feedPage(before: cursor, limit: limit) }
        return try await data.rpc("feed_page", params: FeedPageParams(cursor: cursor, limit: limit))
    }

    func comments(postID: UUID, before cursor: FeedCursor?, limit: Int = 30) async throws -> [PostCommentDTO] {
        #if DEBUG
        try DebugFaultInjector.throwIfFaulted(
            cursor == nil ? DebugFaultInjector.Operation.postCommentsInitial : DebugFaultInjector.Operation.postCommentsLoadMore)
        #endif
        if await DemoWorld.shared.isActive { return await DemoWorld.shared.comments(postID: postID) }
        return try await data.rpc("post_comments_page", params: CommentsPageParams(
            pPostId: postID, pBefore: cursor?.createdAt, pBeforeId: cursor?.postID, pLimit: limit))
    }

    // MARK: Writing

    func toggleCheers(postID: UUID) async throws -> ToggleCheersDTO {
        #if DEBUG
        try DebugFaultInjector.throwIfFaulted(DebugFaultInjector.Operation.toggleCheers)
        #endif
        if await DemoWorld.shared.isActive { return await DemoWorld.shared.toggleCheers(postID: postID) }
        return try await data.rpc("toggle_post_cheers", params: PostIDParams(pPostId: postID))
    }

    @discardableResult
    func createPost(body: String?, imagePath: String?, placeLabel: String?, pubID: UUID?) async throws -> UUID {
        #if DEBUG
        try DebugFaultInjector.throwIfFaulted(DebugFaultInjector.Operation.createPost)
        #endif
        if await DemoWorld.shared.isActive {
            return await DemoWorld.shared.createPost(body: body, imagePath: imagePath,
                                                      placeLabel: placeLabel, pubID: pubID)
        }
        let created: CreatedPostDTO = try await data.rpc("create_post", params: CreatePostParams(
            pBody: body, pImagePath: imagePath, pPlaceLabel: placeLabel, pPubId: pubID))
        return created.postId
    }

    func deletePost(_ postID: UUID) async throws {
        #if DEBUG
        try DebugFaultInjector.throwIfFaulted(DebugFaultInjector.Operation.deletePost)
        #endif
        if await DemoWorld.shared.isActive { await DemoWorld.shared.deletePost(postID); return }
        try await data.rpcVoid("delete_post", params: PostIDParams(pPostId: postID))
    }

    @discardableResult
    func addComment(postID: UUID, body: String, mentions: [UUID]) async throws -> UUID {
        #if DEBUG
        // Generalised from a one-off `-uiTestForceOffline` hook that covered only this call — see
        // `DebugFaultInjector`'s doc for why the check lives here, at the repository boundary,
        // rather than duplicated across every method that wants one.
        try DebugFaultInjector.throwIfFaulted(DebugFaultInjector.Operation.addComment)
        #endif
        if await DemoWorld.shared.isActive {
            return await DemoWorld.shared.addComment(postID: postID, body: body, mentions: mentions)
        }
        let created: CreatedCommentDTO = try await data.rpc("add_comment", params: AddCommentParams(
            pPostId: postID, pBody: body, pMentions: mentions))
        return created.commentId
    }

    func deleteComment(_ commentID: UUID) async throws {
        #if DEBUG
        try DebugFaultInjector.throwIfFaulted(DebugFaultInjector.Operation.deleteComment)
        #endif
        if await DemoWorld.shared.isActive { await DemoWorld.shared.deleteComment(commentID); return }
        try await data.rpcVoid("delete_comment", params: CommentIDParams(pCommentId: commentID))
    }

    // MARK: Moderation and data rights

    func reportPost(_ postID: UUID, category: ReportCategory, details: String?) async throws {
        #if DEBUG
        try DebugFaultInjector.throwIfFaulted(DebugFaultInjector.Operation.reportPost)
        #endif
        if await DemoWorld.shared.isActive { return }
        _ = try await data.rpc("report_post", params: ReportPostParams(
            pPostId: postID, pCategory: category.rawValue, pDetails: details)) as ReportAckDTO
    }

    func reportComment(_ commentID: UUID, category: ReportCategory, details: String?) async throws {
        #if DEBUG
        try DebugFaultInjector.throwIfFaulted(DebugFaultInjector.Operation.reportComment)
        #endif
        if await DemoWorld.shared.isActive { return }
        _ = try await data.rpc("report_comment", params: ReportCommentParams(
            pCommentId: commentID, pCategory: category.rawValue, pDetails: details)) as ReportAckDTO
    }

    /// DSGVO Art. 15/20 self-service export. Returned as raw bytes so the caller can hand the
    /// user the exact document the server produced, without a lossy re-encode.
    func exportMyData() async throws -> Data {
        #if DEBUG
        try DebugFaultInjector.throwIfFaulted(DebugFaultInjector.Operation.exportMyData)
        #endif
        if await DemoWorld.shared.isActive { return Data("{\"demo\":true}".utf8) }
        return try await data.rpcRaw("export_my_data")
    }
}
