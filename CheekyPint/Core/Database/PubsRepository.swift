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

    /// Search nearby / by name+city. Region biases results when a coordinate is provided.
    func search(matching query: String, near coordinate: CLLocationCoordinate2D?) async throws -> [PubSearchResult] {
        if await DemoWorld.shared.isActive && coordinate == nil { return await DemoWorld.shared.pubSearch() }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query.isEmpty ? "pub" : query
        if let coordinate {
            request.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 6000, longitudinalMeters: 6000)
        }
        if #available(iOS 13.0, *) {
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.brewery, .restaurant, .nightlife])
        }
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.map { item in
            let placemark = item.placemark
            return PubSearchResult(
                name: item.name ?? placemark.name ?? "Pub",
                address: placemark.title,
                city: placemark.locality,
                countryCode: placemark.isoCountryCode,
                latitude: placemark.coordinate.latitude,
                longitude: placemark.coordinate.longitude
            )
        }
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
}
