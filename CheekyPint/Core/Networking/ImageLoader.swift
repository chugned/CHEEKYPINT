import Foundation
import UIKit

/// Shared loader for the remote beer photography in the pint-logging catalog.
///
/// The catalog renders 98 cards from only 15 distinct Commons photos — one Pilsner shot backs 60
/// of them. A plain `AsyncImage` per card therefore fired ~98 simultaneous requests for those 15
/// files: `URLSession` does not coalesce identical in-flight requests, and because none had
/// finished yet `URLCache` could not answer any of them either. Wikimedia rate-limits a burst
/// like that outright (HTTP 429, "does not comply with our robot policy"), which is what made the
/// row appear to load forever.
///
/// This collapses the burst to one request per distinct URL, keeps decoded images in memory so
/// the 60 Pilsner cards decode that JPEG once rather than 60 times, and persists to disk so
/// reopening the sheet is instant.
actor ImageLoader {
    static let shared = ImageLoader()

    private let session: URLSession
    private let decoded = NSCache<NSURL, UIImage>()
    /// One task per URL, so N cards sharing a photo await a single download.
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    init() {
        let configuration = URLSessionConfiguration.default
        // Wikimedia blocks clients that do not identify themselves; a descriptive User-Agent with
        // a contact URL is required by their robot policy.
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        configuration.httpAdditionalHeaders = [
            "User-Agent": "CheekyPint/\(version) (https://cheekypint.app)"
        ]
        configuration.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024,
                                          diskCapacity: 256 * 1024 * 1024,
                                          directory: URL.cachesDirectory.appending(path: "BeerImages"))
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        // Keep the fan-out polite even when the user flings through the row.
        configuration.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: configuration)
        decoded.countLimit = 40
    }

    func image(for url: URL) async -> UIImage? {
        if let cached = decoded.object(forKey: url as NSURL) { return cached }
        if let existing = inFlight[url] { return await existing.value }

        let task = Task<UIImage?, Never> { [session] in
            guard let (data, response) = try? await session.data(from: url),
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
