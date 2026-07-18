import Foundation

/// A user-meaningful error surface over Supabase/PostgREST responses. View models translate
/// these into the friendly copy required by every screen's error states (master prompt §22).
enum SupabaseError: Error, Equatable {
    case offline
    case notAuthenticated
    case rateLimited(hint: String?)
    case notFound
    case forbidden
    case server(status: Int, message: String)
    case decoding(String)
    case unknown(String)

    /// Map a Postgres/PostgREST error payload to a case. Custom RPC errors use SQLSTATEs:
    /// P0001 = rate limit, P0002 = not found/forbidden-uniform, 28000 = auth, 42501 = RLS.
    static func from(status: Int, body: Data) -> SupabaseError {
        let payload = try? SupabaseJSON.decoder.decode(PostgRESTError.self, from: body)
        let code = payload?.code
        let message = payload?.message ?? String(data: body, encoding: .utf8) ?? "Request failed"

        switch (status, code) {
        case (401, _), (_, "28000"): return .notAuthenticated
        case (_, "P0001"): return .rateLimited(hint: payload?.hint)
        case (403, _), (_, "42501"): return .forbidden
        case (404, _), (_, "P0002"): return .notFound
        default: return .server(status: status, message: message)
        }
    }

    /// Friendly, non-technical copy for display.
    var friendlyMessage: String {
        switch self {
        case .offline: return "You're offline. We'll try again when you're back."
        case .notAuthenticated: return "Please sign in again."
        case .rateLimited(let hint): return hint ?? "That's a lot at once — give it a moment."
        case .notFound: return "That's not available."
        case .forbidden: return "You don't have access to that."
        case .server: return "Something went wrong. Please try again."
        case .decoding: return "We couldn't read that. Please try again."
        case .unknown(let message): return message
        }
    }
}

/// The shape PostgREST / RPC errors come back in.
struct PostgRESTError: Decodable {
    let message: String?
    let code: String?
    let details: String?
    let hint: String?
}
