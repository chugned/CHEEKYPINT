import XCTest
@testable import CheekyPint

/// Regression coverage for the bug where `ProfileRepository.deleteAccount()` called the bare
/// `delete_account` RPC directly. That RPC only anonymises the profile and tears down the social
/// graph — it never removes storage objects and never deletes the auth user, despite the app's
/// legal documents promising both. The `delete-account` Edge Function does the full job (it runs
/// `delete_account()` itself as step 2, then cleans up storage and deletes the auth user with the
/// service role), so the app must call the function and never the bare RPC directly — calling
/// both would run the anonymisation step twice.
///
/// This exercises the real `ProfileRepository` / `SupabaseData` / `SupabaseAuth` stack — no test
/// double was invented for this — by using the `URLSession` and `KeychainStore` seams those types
/// already take as init parameters: an ephemeral session routes every request through a
/// request-recording `URLProtocol`, and a throwaway Keychain service seeds a fake-but-valid
/// session so no real network/token refresh is needed.
final class DeleteAccountWiringTests: XCTestCase {

    override func tearDown() {
        RecordingURLProtocol.reset()
        super.tearDown()
    }

    func testDeleteAccountCallsTheEdgeFunctionAndNeverTheBareRPC() async throws {
        let config = AppConfig(
            environment: .development,
            supabaseURL: URL(string: "https://example.invalid")!,
            supabaseAnonKey: "test-anon-key",
            universalHost: "example.invalid"
        )

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [RecordingURLProtocol.self]
        let mockSession = URLSession(configuration: sessionConfig)

        // A throwaway Keychain service (not the app's real "app.cheekypint.session") so this
        // never touches real session material and cleans up after itself.
        let keychain = KeychainStore(service: "test.cheekypint.delete-account-wiring.\(UUID().uuidString)")
        let fakeSession = AuthSession(
            accessToken: "fake-access-token",
            refreshToken: "fake-refresh-token",
            expiresAt: Date().addingTimeInterval(3600),
            userID: UUID()
        )
        try keychain.setValue(fakeSession, for: "primary")
        defer { keychain.removeItem(for: "primary") }

        let auth = SupabaseAuth(config: config, keychain: keychain, session: mockSession)
        let data = SupabaseData(config: config, auth: auth, session: mockSession)
        let repository = ProfileRepository(data: data)

        try await repository.deleteAccount()

        let requestedPaths = RecordingURLProtocol.recordedURLs.map(\.path)
        XCTAssertEqual(
            requestedPaths, ["/functions/v1/delete-account"],
            "deleteAccount() must POST to the delete-account Edge Function exactly once"
        )
        XCTAssertFalse(
            requestedPaths.contains { $0.contains("rpc/delete_account") },
            "deleteAccount() must never call the bare delete_account RPC directly — the Edge " +
            "Function already runs it as its own step 2"
        )
    }
}

/// Records every request URL it sees and answers with a canned success body, so the test above
/// can assert on *what was called* without a real backend.
private final class RecordingURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storage: [URL] = []

    static var recordedURLs: [URL] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    static func reset() {
        lock.lock(); storage = []; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url {
            Self.lock.lock(); Self.storage.append(url); Self.lock.unlock()
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"deleted":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
