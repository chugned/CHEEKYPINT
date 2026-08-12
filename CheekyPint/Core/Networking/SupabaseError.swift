import Foundation

/// A user-meaningful error surface over Supabase/PostgREST responses. View models translate
/// these into the friendly copy required by every screen's error states (master prompt §22).
enum SupabaseError: Error, Equatable {
    case offline
    case notAuthenticated
    case rateLimited(hint: String?)
    case notFound
    case forbidden
    /// SQLSTATE `22023` ("invalid_parameter_value"): every RPC in this schema reuses this one
    /// code as a general-purpose "reject with a short, hand-written, already user-appropriate
    /// sentence" bucket — e.g. `report_post`/`report_comment`'s `'Cannot report yourself'`,
    /// `create_post`'s `'A post needs a photo or some words'` / `'Image must be in your own
    /// folder'`, `add_comment`'s `'A comment needs some words'`. Unlike `.server` below, whose
    /// message may be an unreviewed technical/internal string not meant for display, every
    /// `22023` message in this codebase is deliberately phrased for a user to read as-is — so
    /// this case carries it straight through instead of collapsing it to a generic string.
    case validation(String)
    case server(status: Int, message: String)
    case decoding(String)
    case unknown(String)

    /// Map a Postgres/PostgREST error payload to a case. Custom RPC errors use SQLSTATEs:
    /// P0001 = rate limit, P0002 = not found/forbidden-uniform, 28000 = auth, 42501 = RLS,
    /// 22023 = a hand-written validation message (see `.validation`'s doc).
    static func from(status: Int, body: Data) -> SupabaseError {
        let payload = try? SupabaseJSON.decoder.decode(PostgRESTError.self, from: body)
        let code = payload?.code
        let message = payload?.message ?? String(data: body, encoding: .utf8) ?? "Request failed"

        switch (status, code) {
        case (401, _), (_, "28000"): return .notAuthenticated
        case (_, "P0001"): return .rateLimited(hint: payload?.hint)
        case (403, _), (_, "42501"): return .forbidden
        case (404, _), (_, "P0002"): return .notFound
        case (_, "22023"): return .validation(message)
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
        case .validation(let message): return message
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
