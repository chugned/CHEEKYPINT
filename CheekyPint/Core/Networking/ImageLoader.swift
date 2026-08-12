import Foundation
import UIKit
import os

/// Shared loader for images fetched from Supabase Storage (avatars, post photos).
///
/// The catalog renders many cards that can share the same underlying photo. A plain `AsyncImage`
/// per card therefore fires one simultaneous request per card: `URLSession` does not coalesce
/// identical in-flight requests, and because none had finished yet `URLCache` could not answer
/// any of them either, so a shared photo could appear to load forever under a burst of duplicate
/// requests.
///
/// This collapses the burst to one request per distinct URL, keeps decoded images in memory so a
/// shared photo decodes once rather than once per card, and persists to disk so reopening the
/// screen is instant.
actor ImageLoader {
    static let shared = ImageLoader()

    private let session: URLSession
    private let cache: URLCache
    private let decoded = NSCache<NSURL, UIImage>()
    private let logger = Logger(subsystem: "app.cheekypint", category: "ImageLoader")
    /// One task per URL, so N cards sharing a photo await a single download.
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    /// Supplies the caller's current access token. Post photos live in a private bucket whose
    /// read policy is evaluated per request, so every fetch must carry the caller's identity;
    /// a static header cannot, because tokens refresh.
    private var tokenProvider: (@Sendable () async -> String?)?

    /// The only host the bearer token is ever attached to. Today there is a single caller (post
    /// photos, from the Supabase Storage host), but `image(for:)` takes *any* URL with no host
    /// check, so the next non-Supabase caller — a CDN fallback, a support attachment, anything —
    /// would silently send the user's session JWT off-domain. `nil` (the default, before the app
    /// wires it up) means no token is ever attached.
    private var allowedTokenHost: String?

    init() {
        let configuration = URLSessionConfiguration.default
        // A descriptive User-Agent identifying the app and a contact URL is good manners for any
        // backend, including the Supabase Storage endpoints this loader now fetches from.
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        configuration.httpAdditionalHeaders = [
            "User-Agent": "CheekyPint/\(version) (https://cheekypint.app)"
        ]
        // Named "BeerImages" from when this loader served Commons beer photography; left as-is
        // since renaming would orphan users' existing on-disk caches for no benefit — the
        // contents (Supabase Storage images) no longer match the name.
        let cache = URLCache(memoryCapacity: 16 * 1024 * 1024,
                             diskCapacity: 256 * 1024 * 1024,
                             directory: URL.cachesDirectory.appending(path: "BeerImages"))
        configuration.urlCache = cache
        self.cache = cache
        // `.returnCacheDataElseLoad` answers from disk forever with no revalidation, keyed only
        // on URL — it ignores `Authorization` entirely. For a *private* bucket that is exactly
        // wrong: unfriending, blocking or deleting a post revokes access server-side, but a
        // cached response never checks back in to notice. `.useProtocolCachePolicy` still lets a
        // shared photo answer from cache, but only after the normal HTTP freshness/revalidation
        // rules (ETag/Last-Modified) say it's still allowed to. Combined with `clear()` below
        // (called on sign-out and account deletion), a revoked photo cannot outlive the session
        // that could see it.
        configuration.requestCachePolicy = .useProtocolCachePolicy
        // Keep the fan-out polite even when the user flings through the row.
        configuration.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: configuration)
        decoded.countLimit = 40
    }

    func setTokenProvider(_ provider: @escaping @Sendable () async -> String?) {
        tokenProvider = provider
    }

    func setAllowedHost(_ host: String?) {
        allowedTokenHost = host
    }

    /// Drops every cached response (disk + memory, via the shared `URLCache`) and every decoded
    /// image held in memory. A private post photo must not survive the session that could see it
    /// — see the doc on `requestCachePolicy` above — so this is called from both
    /// `SessionController.signOut()` and the account-deletion path (`DeleteAccountView.delete()`,
    /// after `deleteAccount()` succeeds): sign-out alone isn't enough, because deleting the
    /// account is a separate flow that a future refactor could route around `signOut()`.
    func clear() {
        cache.removeAllCachedResponses()
        decoded.removeAllObjects()
    }

    func image(for url: URL) async -> UIImage? {
        if let cached = decoded.object(forKey: url as NSURL) { return cached }
        if let existing = inFlight[url] { return await existing.value }

        // Read actor-isolated state (`tokenProvider`) before entering the detached task, and
        // capture the resulting value rather than `self`. Reaching back into the actor from
        // inside the task closure would force every fetch through an extra actor hop and could
        // reintroduce the duplicate-request problem `inFlight` de-duplication exists to solve.
        let tokenProvider = self.tokenProvider
        let allowedTokenHost = self.allowedTokenHost
        let task = Task<UIImage?, Never> { [session, logger] in
            // Friend-circle/demo mode's seeded photos are bundled files, not network resources —
            // see `ProfileRepository.postImageURL`'s `local-post-image/` handling. `URLSession`
            // can fetch `file://` URLs, but the response is a plain `URLResponse`, never an
            // `HTTPURLResponse`, so the status-200 check below would always fail it; read the
            // bytes directly instead, and never attempt to attach a bearer token to a local file.
            if url.isFileURL {
                guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
                    logger.error("Local image read failed for \(url.lastPathComponent, privacy: .public)")
                    return nil
                }
                return image
            }

            var request = URLRequest(url: url)
            if let allowedTokenHost, url.host == allowedTokenHost, let token = await tokenProvider?() {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse
            else { return nil }
            guard http.statusCode == 200 else {
                // A 401 (stale/missing token) and a genuinely-deleted object both silently
                // resolved to `nil` before this, so neither announced itself in production.
                logger.error("Image fetch failed: status \(http.statusCode, privacy: .public) for \(url.lastPathComponent, privacy: .public)")
                return nil
            }
            guard let image = UIImage(data: data) else { return nil }
            return image
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { decoded.setObject(image, forKey: url as NSURL) }
        return image
    }
}
