import Foundation

/// A persisted auth session from Supabase GoTrue. Stored in the Keychain.
struct AuthSession: Codable, Sendable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let userID: UUID

    /// Refresh a little before actual expiry to avoid racing a 401.
    func isExpired(now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        now.addingTimeInterval(leeway) >= expiresAt
    }
}

/// The GoTrue token response (`/auth/v1/token`, `/auth/v1/verify`).
struct GoTrueTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let user: GoTrueUser

    struct GoTrueUser: Decodable { let id: UUID }

    func makeSession(now: Date = Date()) -> AuthSession {
        AuthSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: now.addingTimeInterval(TimeInterval(expiresIn)),
            userID: user.id
        )
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case user
    }
}
