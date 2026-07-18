import Foundation
import MapKit
import CheekyPintCore

/// A pub found via MapKit local search (not yet persisted).
struct PubSearchResult: Identifiable, Sendable, Hashable {
    let id = UUID()
    let name: String
    let address: String?
    let city: String?
    let countryCode: String?
    let latitude: Double
    let longitude: Double
    let phoneNumber: String?
    let url: URL?

    init(
        name: String,
        address: String?,
        city: String?,
        countryCode: String?,
        latitude: Double,
        longitude: Double,
        phoneNumber: String? = nil,
        url: URL? = nil
    ) {
        self.name = name
        self.address = address
        self.city = city
        self.countryCode = countryCode
        self.latitude = latitude
        self.longitude = longitude
        self.phoneNumber = phoneNumber
        self.url = url
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private struct PubInsert: Encodable, Sendable {
    let name: String
    let formattedAddress: String?
    let city: String?
    let countryCode: String?
    let latitude: Double
    let longitude: Double
    let externalSource: String
    let createdBy: UUID
}

/// Pub search (Apple MapKit, master prompt §11) + persistence of the stable pub record chosen
/// when logging. Location is only ever used here, on demand — never in the background.
struct PubsRepository: Sendable {
    let data: SupabaseData

    private static let nearbyPubQueries = [
        "pub",
        "bar",
        "brewery",
        "beer",
        "beer garden",
        "tavern",
        "irish pub",
        "craft beer",
        "Biergarten",
        "Brauerei",
        "Wirtshaus",
        "Gasthaus",
        "Beisl",
    ]

    /// Search nearby / by name+city. Region biases results when a coordinate is provided.
    func search(matching query: String, near coordinate: CLLocationCoordinate2D?) async throws -> [PubSearchResult] {
        if await DemoWorld.shared.isActive && coordinate == nil { return await DemoWorld.shared.pubSearch() }
        return try await mapKitSearch(matching: query.isEmpty ? "pub" : query, near: coordinate, radiusMeters: 6000)
    }

    /// A more exhaustive nearest-pub scan. Apple does not expose "every pub" as a single API
    /// result, so this runs several local-search terms, merges duplicates, and sorts by distance.
    func nearbyPubs(near coordinate: CLLocationCoordinate2D, limit: Int = 60) async throws -> [PubSearchResult] {
        var collected: [PubSearchResult] = []
        var firstError: Error?

        for query in Self.nearbyPubQueries {
            do {
                let results = try await mapKitSearch(matching: query, near: coordinate, radiusMeters: 9000)
                collected.append(contentsOf: results)
            } catch {
                firstError = firstError ?? error
            }
        }

        let merged = deduplicated(collected)
            .sorted { distance(from: coordinate, to: $0.coordinate) < distance(from: coordinate, to: $1.coordinate) }

        if merged.isEmpty, let firstError {
            throw firstError
        }

        return Array(merged.prefix(limit))
    }

    /// Find an existing matching pub or create one, returning the stable record to attach to a
    /// pint entry.
    func persist(_ result: PubSearchResult) async throws -> Pub {
        if await DemoWorld.shared.isActive { return await DemoWorld.shared.persist(result) }
        // Try to reuse an existing pub by name + city to avoid duplicates.
        let existing: [Pub] = try await data.select("pubs", query: [
            URLQueryItem(name: "name", value: "eq.\(result.name)"),
            URLQueryItem(name: "city", value: result.city.map { "eq.\($0)" } ?? "is.null"),
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "limit", value: "1"),
        ])
        if let pub = existing.first { return pub }

        guard let uid = await data.auth.currentUserID else { throw SupabaseError.notAuthenticated }
        let insert = PubInsert(
            name: result.name,
            formattedAddress: result.address,
            city: result.city,
            countryCode: result.countryCode,
            latitude: result.latitude,
            longitude: result.longitude,
            externalSource: PubSource.mapkit.rawValue,
            createdBy: uid
        )
        let rows: [Pub] = try await data.insert("pubs", values: insert)
        guard let pub = rows.first else { throw SupabaseError.unknown("Pub not created") }
        return pub
    }

    private func mapKitSearch(
        matching query: String,
        near coordinate: CLLocationCoordinate2D?,
        radiusMeters: CLLocationDistance
    ) async throws -> [PubSearchResult] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let coordinate {
            request.region = MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: radiusMeters,
                longitudinalMeters: radiusMeters
            )
        }
        request.resultTypes = .pointOfInterest
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.brewery, .restaurant, .nightlife])

        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.compactMap { item -> PubSearchResult? in
            let placemark = item.placemark
            guard CLLocationCoordinate2DIsValid(placemark.coordinate) else { return nil }
            return PubSearchResult(
                name: item.name ?? placemark.name ?? "Pub",
                address: placemark.title,
                city: placemark.locality,
                countryCode: placemark.isoCountryCode,
                latitude: placemark.coordinate.latitude,
                longitude: placemark.coordinate.longitude,
                phoneNumber: item.phoneNumber,
                url: item.url
            )
        }
    }

    private func deduplicated(_ results: [PubSearchResult]) -> [PubSearchResult] {
        var kept: [PubSearchResult] = []
        var seenKeys = Set<String>()

        for result in results {
            let key = dedupeKey(for: result)
            if seenKeys.contains(key) { continue }
            if kept.contains(where: { sameVenue($0, result) }) { continue }
            seenKeys.insert(key)
            kept.append(result)
        }

        return kept
    }

    private func dedupeKey(for result: PubSearchResult) -> String {
        let normalizedName = result.name
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        let roundedLatitude = Int((result.latitude * 10_000).rounded())
        let roundedLongitude = Int((result.longitude * 10_000).rounded())
        return "\(normalizedName)-\(roundedLatitude)-\(roundedLongitude)"
    }

    private func sameVenue(_ lhs: PubSearchResult, _ rhs: PubSearchResult) -> Bool {
        let namesMatch = lhs.name.compare(rhs.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        return namesMatch && distance(from: lhs.coordinate, to: rhs.coordinate) < 90
    }

    private func distance(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
    }
}
