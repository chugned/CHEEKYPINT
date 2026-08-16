import Foundation
import MapKit

/// What the last query fragment did. Distinguishing `.noMatches` from `.failed` is the whole
/// point (`docs/STATE_AUDIT.md`'s Medium finding): before this existed, `PlaceCompleter` collapsed
/// "the search ran and genuinely found nothing" and "the search itself could not run" (offline,
/// etc.) into the same silent `results = []`, so a real pub name typed while offline rendered
/// identically to gibberish — no way for `PlacePickerSheet` to tell the user which one happened.
enum PlaceSearchStatus: Equatable, Sendable {
    /// No query typed yet, or the field was just cleared — nothing to report either way.
    case idle
    /// The completer has at least one suggestion; `results` is non-empty.
    case results
    /// The completer ran successfully and returned zero suggestions for a non-empty query — a
    /// genuine "nothing matches", not a failure.
    case noMatches
    /// The completer's request itself failed (e.g. offline) — `completer(_:didFailWithError:)`
    /// fired. Distinct from `.noMatches` so the picker can invite a retry instead of implying the
    /// search simply came up empty.
    case failed
}

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
    /// See `PlaceSearchStatus`. `PlacePickerSheet` reads this to decide what, if anything, to show
    /// below the (possibly empty) `results` list.
    private(set) var status: PlaceSearchStatus = .idle

    /// Feeds `completer.queryFragment`. Clearing the field clears `results` immediately rather
    /// than waiting on a delegate callback that may never arrive for an empty fragment.
    var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            #if DEBUG
            // Deterministic seam for UI tests/screenshots — see `DebugFaultInjector.Operation
            // .placeSearch`'s doc for why this can't be `throwIfFaulted` at a repository boundary
            // the way every other faultable operation is. A complete no-op, falling straight
            // through to the real completer below, whenever neither launch argument is set.
            if !query.isEmpty {
                if DebugFaultInjector.isForcedEmpty(DebugFaultInjector.Operation.placeSearch) {
                    results = []
                    status = .noMatches
                    return
                }
                if DebugFaultInjector.isFaulted(DebugFaultInjector.Operation.placeSearch) {
                    results = []
                    status = .failed
                    return
                }
            }
            #endif
            completer.queryFragment = query
            if query.isEmpty {
                results = []
                status = .idle
            }
        }
    }

    override init() {
        super.init()
        completer.resultTypes = [.address, .pointOfInterest]
        completer.delegate = self
    }

    /// `BroadLocationField`'s init (`Core/Location/BroadLocationField.swift`): a broad-area field
    /// has no use for point-of-interest suggestions — a business name is not a "broad area" any
    /// more than a street address is — so it asks for `.address` alone rather than this type's
    /// usual address+POI mix. A separate initializer rather than a default-valued parameter on
    /// the one above, so `PlacePickerSheet`'s existing `PlaceCompleter()` call is untouched byte
    /// for byte rather than resolving through a default argument.
    init(resultTypes: MKLocalSearchCompleter.ResultType) {
        super.init()
        completer.resultTypes = resultTypes
        completer.delegate = self
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        Task { @MainActor in
            self.results = self.completer.results
            self.status = Self.resolvedStatus(resultsCount: self.results.count, failed: false)
        }
    }

    /// A failed completion (no network, etc.) must never block typed free text — that always
    /// works regardless of whether the completer can reach anything — so this still clears
    /// `results`. What changed: `status` now records that this was a genuine failure, not a
    /// zero-result success, so `PlacePickerSheet` can tell the two apart instead of rendering both
    /// as the same silent, message-less empty list.
    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            self.results = []
            self.status = Self.resolvedStatus(resultsCount: 0, failed: true)
        }
    }

    // MARK: - Pure helper (unit tested; see PlacePickerTests)

    /// The distinguishing rule itself, split out of the two delegate callbacks above so it's
    /// testable synchronously: those callbacks only ever run via `MKLocalSearchCompleter`'s own
    /// async delegate dispatch (hopping through an unstructured `Task` to reach `@MainActor`),
    /// which a unit test can't drive deterministically without either touching the real network or
    /// depending on `Task` scheduling order. This is the one fact that matters — "a failure is
    /// never a zero-result success, no matter how many results there were" — with nothing else to
    /// get wrong.
    nonisolated static func resolvedStatus(resultsCount: Int, failed: Bool) -> PlaceSearchStatus {
        if failed { return .failed }
        return resultsCount == 0 ? .noMatches : .results
    }
}
