import Foundation

/// Owns the auth session and all token I/O against Supabase GoTrue. An `actor` so token
/// refresh is serialised — concurrent requests can't kick off duplicate refreshes or read a
/// half-updated session. Supports Sign in with Apple (primary) and email magic link / OTP
/// (secondary), per master prompt §4. No Google/Facebook.
actor SupabaseAuth {
    private let config: AppConfig
    private let keychain: KeychainStore
    private let session: URLSession
    private let account = "primary"
    private var current: AuthSession?
    private var refreshTask: Task<AuthSession, Error>?

    init(config: AppConfig = .current, keychain: KeychainStore = KeychainStore(), session: URLSession = .shared) {
        self.config = config
        self.keychain = keychain
        self.session = session
        self.current = keychain.value(AuthSession.self, for: account)
    }

    var currentUserID: UUID? { current?.userID }
    var hasSession: Bool { current != nil }

    /// A valid bearer token, refreshing if it is expired/near expiry.
    func validAccessToken() async throws -> String {
        guard let session = current else { throw SupabaseError.notAuthenticated }
        guard session.isExpired() else { return session.accessToken }
        return try await refresh().accessToken
    }

    // MARK: Sign in with Apple

    /// Exchange an Apple identity token (from ASAuthorization) for a Supabase session.
    func signInWithApple(idToken: String, nonce: String) async throws -> AuthSession {
        let body: [String: String] = ["provider": "apple", "id_token": idToken, "nonce": nonce]
        let response: GoTrueTokenResponse = try await post("token", query: [URLQueryItem(name: "grant_type", value: "id_token")], json: body)
        return persist(response.makeSession())
    }

    // MARK: Email magic link / OTP

    /// Send a magic link / one-time code to `email`. Creates the user if new.
    func sendEmailOTP(email: String) async throws {
        let _: EmptyResponse = try await post("otp", json: EmailOTPBody(email: email, create_user: true))
    }

    /// Verify a 6-digit email OTP, returning a session.
    func verifyEmailOTP(email: String, token: String) async throws -> AuthSession {
        let body: [String: String] = ["type": "email", "email": email, "token": token]
        let response: GoTrueTokenResponse = try await post("verify", json: body)
        return persist(response.makeSession())
    }

    /// Handle a magic-link callback URL of the form `cheekypint://auth-callback#access_token=...`.
    func handleCallbackURL(_ url: URL) async throws -> AuthSession {
        guard let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment else {
            throw SupabaseError.notAuthenticated
        }
        let params = Dictionary(uniqueKeysWithValues: fragment.split(separator: "&").compactMap { pair -> (String, String)? in
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]).removingPercentEncoding ?? String(parts[1]))
        })
        guard let access = params["access_token"], let refresh = params["refresh_token"] else {
            throw SupabaseError.notAuthenticated
        }
        // Resolve the user id from the access token's `sub` claim.
        let userID = try Self.subject(fromJWT: access)
        let expiresIn = Int(params["expires_in"] ?? "3600") ?? 3600
        return persist(AuthSession(accessToken: access, refreshToken: refresh,
                                   expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)), userID: userID))
    }

    // MARK: Lifecycle

    func refresh() async throws -> AuthSession {
        if let task = refreshTask { return try await task.value }
        guard let refreshToken = current?.refreshToken else { throw SupabaseError.notAuthenticated }

        let task = Task { () throws -> AuthSession in
            defer { refreshTask = nil }
            let response: GoTrueTokenResponse = try await post(
                "token", query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
                json: ["refresh_token": refreshToken])
            return persist(response.makeSession())
        }
        refreshTask = task
        return try await task.value
    }

    func signOut() async {
        if let token = current?.accessToken {
            _ = try? await post("logout", json: EmptyBody(), bearer: token) as EmptyResponse
        }
        current = nil
        keychain.removeItem(for: account)
    }

    // MARK: - Internals

    @discardableResult
    private func persist(_ session: AuthSession) -> AuthSession {
        current = session
        try? keychain.setValue(session, for: account)
        return session
    }

    private func post<Body: Encodable, Response: Decodable>(
        _ path: String,
        query: [URLQueryItem] = [],
        json body: Body,
        bearer: String? = nil
    ) async throws -> Response {
        var components = URLComponents(url: config.authURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(bearer ?? config.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw SupabaseError.unknown("No response") }
        guard (200..<300).contains(http.statusCode) else { throw SupabaseError.from(status: http.statusCode, body: data) }
        if Response.self == EmptyResponse.self { return EmptyResponse() as! Response }
        return try SupabaseJSON.decoder.decode(Response.self, from: data)
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: request) }
        catch let error as URLError where error.code == .notConnectedToInternet { throw SupabaseError.offline }
    }

    /// Extract the `sub` (user id) claim from a JWT without verifying the signature (the server
    /// already issued it; we only need the id locally).
    private static func subject(fromJWT token: String) throws -> UUID {
        let segments = token.split(separator: ".")
        guard segments.count == 3 else { throw SupabaseError.notAuthenticated }
        var base64 = String(segments[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = json["sub"] as? String, let id = UUID(uuidString: sub) else {
            throw SupabaseError.notAuthenticated
        }
        return id
    }
}

struct EmptyBody: Encodable {}
struct EmptyResponse: Decodable {}
/// GoTrue `/otp` body. snake_case matches the API (auth uses a plain JSONEncoder).
struct EmailOTPBody: Encodable { let email: String; let create_user: Bool }
