import Foundation
import MapKit

/// Drives `MKLocalSearchCompleter` for `PlacePickerSheet`. Deliberately has no notion of the
/// user's own location: `resultTypes` is `[.address, .pointOfInterest]` and `region` is never
/// set, so a query like "Prague" resolves to the city itself rather than being biased toward, or
/// silently limited by, wherever the device happens to be. That is what lets this picker return
/// both cities and venues with zero location permission — the product requirement it exists to
/// satisfy ("you can just add prague, and thats it").
///
/// `MKLocalSearchCompleter`/`MKLocalSearchCompleterDelegate` are not `Sendable`, so this class
/// stays pinned to `@MainActor` end to end. The delegate callbacks are `nonisolated` — the
/// protocol itself isn't actor-isolated, so that's what satisfies it — and they only ever touch
/// `self`, never the callback's own delegate-object parameter, before hopping back with
/// `Task { @MainActor in ... }`. That mirrors `LocationService`'s existing pattern in this
/// codebase (`Core/Location/LocationService.swift`) and needs no `@unchecked Sendable` or
/// `nonisolated(unsafe)` anywhere.
@MainActor
@Observable
final class PlaceCompleter: NSObject, MKLocalSearchCompleterDelegate {
    private let completer = MKLocalSearchCompleter()

    private(set) var results: [MKLocalSearchCompletion] = []

    /// Feeds `completer.queryFragment`. Clearing the field clears `results` immediately rather
    /// than waiting on a delegate callback that may never arrive for an empty fragment.
    var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            completer.queryFragment = query
            if query.isEmpty { results = [] }
        }
    }

    override init() {
        super.init()
        completer.resultTypes = [.address, .pointOfInterest]
        completer.delegate = self
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        Task { @MainActor in
            self.results = self.completer.results
        }
    }

    /// A failed completion (no network, etc.) is not an error worth surfacing — typed free text
    /// always works regardless of whether the completer can reach anything — so this just clears
    /// results instead of setting an error state for the picker to show.
    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            self.results = []
        }
    }
}
