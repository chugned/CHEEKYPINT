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
    /// A one-time email code GoTrue refused. Deliberately *not* split into "wrong" and "expired":
    /// GoTrue answers both with the identical payload — verified against a real local GoTrue
    /// v2.195.0, which returns `403 {"code":403,"error_code":"otp_expired","msg":"Token has
    /// expired or is invalid"}` for a wrong 6-digit code, a 5-digit one, an alphabetic one, an
    /// already-used one, *and* for an email that has never been sent a code at all. There is no
    /// field anywhere in that response that separates the two, so copy that claimed to know which
    /// had happened would be inventing it. See `SupabaseErrorTests` and `EmailOTPAuthTests`.
    case invalidOrExpiredCode
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

    /// Map a **GoTrue** (`/auth/v1/...`) error payload to a case.
    ///
    /// GoTrue does not speak PostgREST's error shape, and that difference is not cosmetic:
    /// PostgREST sends `{"message":…,"code":"<string>",…}` while GoTrue sends
    /// `{"code":<int>,"error_code":"<string>","msg":…}`. Decoding a GoTrue body as
    /// `PostgRESTError` *throws* — `code` is a number there, not a string — so `from(status:body:)`
    /// sees no payload at all and every auth failure collapses into `.server`, whose
    /// `friendlyMessage` is the generic "Something went wrong. Please try again."
    ///
    /// That generic string is exactly the wrong answer for the two failures this flow actually
    /// hits. A 429 from the built-in SMTP sender ("you can only request this after 47 seconds")
    /// would read as an unexplained breakage, and a mistyped code — a 403 — would map to
    /// `.forbidden`'s "You don't have access to that", which sounds like an account problem rather
    /// than four wrong digits. Both would send the user looking for the wrong fix.
    ///
    /// Status codes and payloads below are the ones a real local GoTrue v2.195.0 returned; see the
    /// `EmailOTPAuthTests` "live GoTrue" cases, which re-derive them against the running server so
    /// this mapping cannot quietly rot if GoTrue changes its wire format.
    static func fromAuth(status: Int, body: Data) -> SupabaseError {
        let payload = try? SupabaseJSON.goTrueDecoder.decode(GoTrueError.self, from: body)
        switch (status, payload?.errorCode) {
        // The server's own sentence carries the number of seconds left, which nothing on the
        // client can compute, so it is passed through as the hint rather than paraphrased.
        case (429, _): return .rateLimited(hint: payload?.msg)
        case (_, "otp_expired"): return .invalidOrExpiredCode
        // `validation_failed` is GoTrue's own already-user-readable rejection of the input we
        // sent, e.g. "Unable to validate email address: invalid format".
        case (_, "validation_failed"): return .validation(payload?.msg ?? "That didn't look right.")
        case (401, _): return .notAuthenticated
        case (403, _): return .forbidden
        default:
            let message = payload?.msg ?? String(data: body, encoding: .utf8) ?? "Request failed"
            return .server(status: status, message: message)
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
        case .invalidOrExpiredCode:
            return "That code didn't work. It's either mistyped or past its expiry — send a new one and we'll try again."
        case .server: return "Something went wrong. Please try again."
        case .decoding: return "We couldn't read that. Please try again."
        case .unknown(let message): return message
        }
    }
}

extension Error {
    /// True for both `CancellationError` (thrown at a cooperative-cancellation checkpoint) and
    /// `URLError.cancelled` (what `URLSession`'s async APIs throw when the owning `Task` is
    /// cancelled mid-request) — the two shapes a cancelled request from this networking layer
    /// actually arrives in.
    ///
    /// Lives here, next to `SupabaseError`, because that two-case fact is a property of this
    /// networking stack, not of any one screen. `FeedViewModel` and `PostCommentsViewModel` each
    /// carried a verbatim `private extension` copy; two owners of one fact about the layer beneath
    /// them is exactly the shape that drifts when a third cancellation representation turns up.
    ///
    /// Callers use it to distinguish "the user navigated away mid-fetch" — an interruption, not a
    /// failure worth surfacing — from a real error.
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if let urlError = self as? URLError, urlError.code == .cancelled { return true }
        return false
    }
}

/// The shape PostgREST / RPC errors come back in.
struct PostgRESTError: Decodable {
    let message: String?
    let code: String?
    let details: String?
    let hint: String?
}

/// The shape GoTrue (`/auth/v1/...`) errors come back in — a different one. Note `code` is a
/// number here, which is why decoding a GoTrue body as `PostgRESTError` fails outright rather
/// than degrading gracefully. Only `error_code` and `msg` are read; `code` merely repeats the
/// HTTP status.
/// Read with `SupabaseJSON.goTrueDecoder`, which applies no key strategy — so, like every other
/// GoTrue type here, it spells its wire names out.
struct GoTrueError: Decodable {
    let errorCode: String?
    let msg: String?

    private enum CodingKeys: String, CodingKey {
        case errorCode = "error_code"
        case msg
    }
}
