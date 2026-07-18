import Foundation
import CheekyPintCore

/// Pub sessions + clinks. Joining is always explicit (token/code/invite); membership is never
/// inferred from proximity (master prompt §12). Clinks are decorative and never change totals.
struct SessionsRepository: Sendable {
    let data: SupabaseData

    /// The caller's current active session, if any (RLS returns only sessions they belong to).
    func fetchActiveSession() async throws -> PubSession? {
        if await DemoWorld.shared.isActive { return await DemoWorld.shared.activeSession() }
        let rows: [PubSession] = try await data.select("pub_sessions", query: [
            URLQueryItem(name: "status", value: "eq.active"),
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "order", value: "started_at.desc"),
            URLQueryItem(name: "limit", value: "1"),
        ])
        return rows.first
    }

    /// Create a session and get the raw join token back once (to render as a QR / share).
    func createSession(pubID: UUID?, name: String?) async throws -> CreatedSessionDTO {
        if await DemoWorld.shared.isActive {
            return CreatedSessionDTO(sessionId: DemoWorld.sessionID, joinToken: FriendToken.generate().rawValue,
                                     startedAt: Date(), status: "active")
        }
        return try await data.rpc("create_pub_session", params: CreateSessionParams(pPubId: pubID, pName: name))
    }

    func joinByToken(_ raw: String) async throws {
        if await DemoWorld.shared.isActive { return }
        let _: [String: String] = try await data.rpc("join_session_by_token", params: RawTokenParams(pRawToken: raw))
    }

    func leave(sessionID: UUID) async throws {
        if await DemoWorld.shared.isActive { return }
        try await data.rpcVoid("leave_session", params: SessionParams(pSessionId: sessionID))
    }

    func end(sessionID: UUID) async throws {
        if await DemoWorld.shared.isActive { return }
        try await data.rpcVoid("end_session", params: SessionParams(pSessionId: sessionID))
    }

    func createClink(sessionID: UUID, participants: [UUID]) async throws {
        if await DemoWorld.shared.isActive { return }
        try await data.rpcVoid("create_clink", params: ClinkParams(pSessionId: sessionID, pParticipants: participants))
    }

    /// Active co-members of a session, for the home "Active friends" strip + clink targets.
    func fetchActiveMembers(sessionID: UUID) async throws -> [SessionMember] {
        if await DemoWorld.shared.isActive {
            return [
                SessionMember(sessionId: sessionID, userId: DemoWorld.aliceID, role: .host),
                SessionMember(sessionId: sessionID, userId: DemoWorld.barnabyID, role: .member),
            ]
        }
        return try await data.select("session_members", query: [
            URLQueryItem(name: "session_id", value: "eq.\(sessionID)"),
            URLQueryItem(name: "left_at", value: "is.null"),
            URLQueryItem(name: "select", value: "*"),
        ])
    }
}
