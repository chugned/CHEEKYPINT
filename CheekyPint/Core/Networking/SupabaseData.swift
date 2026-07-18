import Foundation

/// Thin PostgREST + RPC client. Reads/writes that need privacy logic go through `rpc(...)`
/// (the SECURITY DEFINER functions); simple own-row reads/writes use `select`/`patch`/`insert`.
/// Every request carries the anon apikey plus the caller's bearer token, refreshed on demand.
struct SupabaseData: Sendable {
    let config: AppConfig
    let auth: SupabaseAuth
    let session: URLSession

    init(config: AppConfig = .current, auth: SupabaseAuth, session: URLSession = .shared) {
        self.config = config
        self.auth = auth
        self.session = session
    }

    // MARK: RPC

    /// Call a SECURITY DEFINER function and decode its return value.
    func rpc<Params: Encodable & Sendable, Response: Decodable>(
        _ function: String, params: Params, as: Response.Type = Response.self
    ) async throws -> Response {
        let data = try await perform(
            method: "POST",
            url: config.restURL.appendingPathComponent("rpc/\(function)"),
            body: SupabaseJSON.encoder.encode(params))
        return try decode(Response.self, from: data)
    }

    /// Call a function with no interesting return value.
    func rpcVoid<Params: Encodable & Sendable>(_ function: String, params: Params) async throws {
        _ = try await perform(
            method: "POST",
            url: config.restURL.appendingPathComponent("rpc/\(function)"),
            body: SupabaseJSON.encoder.encode(params))
    }

    func rpcVoid(_ function: String) async throws { try await rpcVoid(function, params: EmptyBody()) }

    // MARK: Table access (own rows only, gated by RLS)

    func select<T: Decodable>(_ table: String, query: [URLQueryItem] = [], as: T.Type = T.self) async throws -> [T] {
        var components = URLComponents(url: config.restURL.appendingPathComponent(table), resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query
        let data = try await perform(method: "GET", url: components.url!, body: nil)
        return try decode([T].self, from: data)
    }

    func insert<Body: Encodable & Sendable, T: Decodable>(_ table: String, values: Body, as: T.Type = T.self) async throws -> [T] {
        let data = try await perform(
            method: "POST",
            url: config.restURL.appendingPathComponent(table),
            body: SupabaseJSON.encoder.encode(values),
            prefer: "return=representation")
        return try decode([T].self, from: data)
    }

    func patch<Body: Encodable & Sendable, T: Decodable>(_ table: String, values: Body, match: [URLQueryItem], as: T.Type = T.self) async throws -> [T] {
        var components = URLComponents(url: config.restURL.appendingPathComponent(table), resolvingAgainstBaseURL: false)!
        components.queryItems = match
        let data = try await perform(
            method: "PATCH", url: components.url!,
            body: SupabaseJSON.encoder.encode(values),
            prefer: "return=representation")
        return try decode([T].self, from: data)
    }

    // MARK: Storage

    /// Upload bytes to a storage bucket and return the object path (bucket-relative). Used for
    /// avatars. Writes are restricted server-side to the caller's own `<uid>/` folder.
    @discardableResult
    func uploadObject(bucket: String, path: String, data bytes: Data, contentType: String) async throws -> String {
        let url = config.storageURL.appendingPathComponent("object/\(bucket)/\(path)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "x-upsert")
        let token = try await auth.validAccessToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.upload(for: request, from: bytes) }
        catch let error as URLError where error.code == .notConnectedToInternet { throw SupabaseError.offline }
        guard let http = response as? HTTPURLResponse else { throw SupabaseError.unknown("No response") }
        guard (200..<300).contains(http.statusCode) else { throw SupabaseError.from(status: http.statusCode, body: data) }
        return path
    }

    /// The public URL for a stored avatar path (the avatars bucket is public-read).
    func publicURL(bucket: String, path: String) -> URL {
        config.storageURL.appendingPathComponent("object/public/\(bucket)/\(path)")
    }

    // MARK: - Core request

    private func perform(method: String, url: URL, body: Data?, prefer: String? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }
        request.httpBody = body

        let token = try await auth.validAccessToken()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .notConnectedToInternet {
            throw SupabaseError.offline
        }
        guard let http = response as? HTTPURLResponse else { throw SupabaseError.unknown("No response") }
        guard (200..<300).contains(http.statusCode) else {
            throw SupabaseError.from(status: http.statusCode, body: data)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        if T.self == EmptyResponse.self { return EmptyResponse() as! T }
        do { return try SupabaseJSON.decoder.decode(T.self, from: data) }
        catch { throw SupabaseError.decoding(String(describing: error)) }
    }
}
