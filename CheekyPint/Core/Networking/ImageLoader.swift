import Foundation
import UIKit

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
    private let decoded = NSCache<NSURL, UIImage>()
    /// One task per URL, so N cards sharing a photo await a single download.
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    /// Supplies the caller's current access token. Post photos live in a private bucket whose
    /// read policy is evaluated per request, so every fetch must carry the caller's identity;
    /// a static header cannot, because tokens refresh.
    private var tokenProvider: (@Sendable () async -> String?)?

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
        configuration.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024,
                                          diskCapacity: 256 * 1024 * 1024,
                                          directory: URL.cachesDirectory.appending(path: "BeerImages"))
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        // Keep the fan-out polite even when the user flings through the row.
        configuration.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: configuration)
        decoded.countLimit = 40
    }

    func setTokenProvider(_ provider: @escaping @Sendable () async -> String?) {
        tokenProvider = provider
    }

    func image(for url: URL) async -> UIImage? {
        if let cached = decoded.object(forKey: url as NSURL) { return cached }
        if let existing = inFlight[url] { return await existing.value }

        // Read actor-isolated state (`tokenProvider`) before entering the detached task, and
        // capture the resulting value rather than `self`. Reaching back into the actor from
        // inside the task closure would force every fetch through an extra actor hop and could
        // reintroduce the duplicate-request problem `inFlight` de-duplication exists to solve.
        let tokenProvider = self.tokenProvider
        let task = Task<UIImage?, Never> { [session] in
            var request = URLRequest(url: url)
            if let token = await tokenProvider?() {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data)
            else { return nil }
            return image
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { decoded.setObject(image, forKey: url as NSURL) }
        return image
    }
}
