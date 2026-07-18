import CoreLocation

/// A deliberately minimal location helper (master prompt §11, §31). It requests **When In Use**
/// authorization ONLY, and ONLY when the user explicitly opens nearby-pub search. It never
/// starts background updates, never requests Always, and never tracks continuously — it fetches
/// a single location on demand and stops.
@MainActor
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    enum Status: Equatable {
        case notDetermined, denied, authorized
    }

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?

    private(set) var status: Status = .notDetermined

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        syncStatus()
    }

    /// Request a single current location, prompting for When-In-Use permission if needed.
    /// The caller should only invoke this after showing an explanation of why (§17).
    func requestOneShotLocation() async throws -> CLLocation {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            manager.requestLocation() // one-shot, not continuous
        }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.syncStatus() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.continuation?.resume(returning: location)
            self.continuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.continuation?.resume(throwing: error)
            self.continuation = nil
        }
    }

    private func syncStatus() {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: status = .authorized
        case .denied, .restricted: status = .denied
        default: status = .notDetermined
        }
    }
}
