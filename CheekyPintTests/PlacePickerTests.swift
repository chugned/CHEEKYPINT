import XCTest
import MapKit
@testable import CheekyPint

/// `PlacePickerSheet`'s pure logic: the free-text-is-always-valid rule, the shared 80-character
/// label clamp, and the pub-vs-place category split. See `testNeitherFileDependsOnLocationPermissionAPIs`
/// for the one behavioural test can't cover — the absence of a CoreLocation dependency.
final class PlacePickerTests: XCTestCase {
    func testTypedTextAloneIsAValidPlace() {
        let place = PlacePickerSheet.freeTextPlace(from: "  Prague  ")
        XCTAssertEqual(place?.label, "Prague", "typed text is trimmed and used verbatim")
        XCTAssertNil(place?.pubID, "a typed city has no pub row")
        XCTAssertNil(PlacePickerSheet.freeTextPlace(from: "   "), "whitespace is not a place")
    }

    /// The only behavioural owner of the 80-character place-label clamp: `freeTextPlace` is the
    /// sole consumer of `ComposePostSheet.placeLabelLimit`, and 80 is pinned here as a literal
    /// (`ComposePostTests.testPlaceLabelLimitMirrorsTheServerClamp` pins the constant to the same
    /// SQL from the other side).
    func testLabelIsClampedToTheServerLimit() {
        let long = String(repeating: "a", count: 200)
        let place = PlacePickerSheet.freeTextPlace(from: long)
        XCTAssertEqual(place?.label.count, 80,
                       "server truncates place_label at 80; clamp before sending")
    }

    /// The clamp is in the server's unit. `left(v_label, 80)` and `posts_place_label_length`'s
    /// `char_length(place_label) <= 80` both count code points, so a label of 60 NFD-decomposed
    /// characters (120 code points) passed a grapheme-based clamp untouched and was then cut by
    /// the server. A label is short enough that the loss is visible — "Café Kürbis…" losing its
    /// tail — which is why this is worth pinning separately from the ASCII case above.
    func testLabelClampIsMeasuredInTheCodePointsPostgresCounts() throws {
        let nfd = String(repeating: "u\u{0308}", count: 60)
        XCTAssertEqual(nfd.count, 60, "fixture: 60 user-visible characters")
        XCTAssertEqual(nfd.unicodeScalars.count, 120, "fixture: 120 code points — what Postgres counts")

        let place = try XCTUnwrap(PlacePickerSheet.freeTextPlace(from: nfd))

        XCTAssertEqual(place.label.unicodeScalars.count, 80,
                       "the clamp must leave nothing for left(v_label, 80) to cut")
        XCTAssertEqual(place.label.count, 40, "80 code points of two-scalar clusters is 40 characters")
    }

    // MARK: - PlaceCompleter.resolvedStatus (docs/STATE_AUDIT.md's Medium finding)

    /// The concrete input that flips this test: before `PlaceSearchStatus` existed,
    /// `PlaceCompleter.completer(_:didFailWithError:)` and a genuine zero-result
    /// `completerDidUpdateResults` both did nothing but `results = []` — indistinguishable to
    /// `PlacePickerSheet`. Reducing `resolvedStatus` back to always returning `.noMatches`
    /// regardless of `failed` (verified by hand) turns this red again.
    func testFailedSearchIsDistinctFromAGenuineZeroResultMatch() {
        let failed = PlaceCompleter.resolvedStatus(resultsCount: 0, failed: true)
        let noMatches = PlaceCompleter.resolvedStatus(resultsCount: 0, failed: false)
        XCTAssertNotEqual(failed, noMatches,
                           "a search that could not run must not look identical to one that ran and found nothing")
        XCTAssertEqual(failed, .failed)
        XCTAssertEqual(noMatches, .noMatches)
    }

    func testSuccessfulSearchWithResultsReportsResults() {
        XCTAssertEqual(PlaceCompleter.resolvedStatus(resultsCount: 3, failed: false), .results)
    }

    /// A failure always wins over whatever `resultsCount` happens to be — `completer(_:
    /// didFailWithError:)` always clears `results` to `[]` before calling this, but the rule
    /// itself shouldn't depend on that call site remembering to.
    func testFailureTakesPriorityOverAStaleNonZeroResultsCount() {
        XCTAssertEqual(PlaceCompleter.resolvedStatus(resultsCount: 5, failed: true), .failed)
    }

    func testPubCategoriesAreTreatedAsPubsAndOthersAsPlaces() {
        XCTAssertTrue(PlacePickerSheet.isPubCategory(.brewery))
        XCTAssertTrue(PlacePickerSheet.isPubCategory(.nightlife))
        XCTAssertFalse(PlacePickerSheet.isPubCategory(.airport))
        XCTAssertFalse(PlacePickerSheet.isPubCategory(nil))
    }

    /// The requirement here is the *absence* of a dependency, which no behavioural test can
    /// observe, so this still has to read source. But a raw `contains("CLLocationManager")` scan
    /// (the brief's original sketch) is fragile in the opposite direction from what you'd expect:
    /// it fails on *correct* code the moment a doc comment explains why the file avoids
    /// CoreLocation — and this codebase's own convention (see every file touched by this task) is
    /// to document exactly that kind of decision in prose. A comment saying "this does not use
    /// LocationService" would trip a bare substring check despite being exactly right.
    ///
    /// This instead matches call/declaration *shapes* — a trailing `(` for a call or
    /// instantiation, a leading `: ` for a type annotation, or a bare name that only makes sense
    /// as a live reference (`CLLocationCoordinate2D`, `CLLocation`, `completer.region`) — which
    /// only appear in real usage, not in prose. A sentence mentioning "LocationService" or
    /// "CLLocationManager" by name, with no trailing `(` or leading `: `, does not trip it (see
    /// `PlaceCompleter`'s and `PlacePickerSheet`'s own header comments, which do exactly that and
    /// still pass).
    ///
    /// The file set is every `.swift` file under `Features/Feed/` — discovered by enumerating the
    /// directory at run time, not named one by one, so a new file added there is covered without
    /// anyone remembering to update a list here — plus `PlaceCompleter.swift` by name.
    /// `PlaceCompleter.swift` isn't swept in by directory the same way: it lives in
    /// `Core/Location/`, right next to `LocationService.swift`, which legitimately uses every one
    /// of these patterns for real; enumerating that whole directory would fail this test against
    /// `LocationService.swift` itself — a correct file this requirement was never about.
    ///
    /// **What this proves, and what it doesn't.** A pass means none of the patterns below appear,
    /// verbatim, in the files scanned, right now. It is a tripwire for the concrete violation
    /// shapes listed here, not a formal proof that no code path anywhere reaches CoreLocation's
    /// permission surface. It would miss, for instance: a dependency injected from a file outside
    /// both the Feed directory and `PlaceCompleter.swift` (a new `Core/` helper called through a
    /// name that matches none of these patterns), a local `typealias` renaming a forbidden type
    /// before use, or the same capability reached via reflection or dynamic dispatch. Treat a
    /// pass as "no known violation shape is present," not "this is impossible" — and extend the
    /// pattern list the next time a new shape turns out to matter.
    ///
    /// Concrete inputs that flip this test:
    /// - Reintroduce `@State private var location = LocationService()` into `PlacePickerSheet`
    ///   (exactly what `PubPickerView` has) — contains `LocationService(`.
    /// - Add `var regionHint: (() async throws -> CLLocationCoordinate2D)? = nil` to
    ///   `PlacePickerSheet`, wire it from `ComposePostSheet.swift` via
    ///   `LocationService().requestOneShotLocation()`, and set `completer.region` from it inside
    ///   `PlaceCompleter` — trips on `CLLocationCoordinate2D` (and, now that `ComposePostSheet.swift`
    ///   is swept in by the `Features/Feed/` enumeration rather than named individually, also on
    ///   `LocationService(`) and on `completer.region`. Verified by hand: applying this exact edit
    ///   turns this test red, naming `CLLocationCoordinate2D` in `PlacePickerSheet.swift` first;
    ///   reverting restores green.
    func testNeitherFileDependsOnLocationPermissionAPIs() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PlacePickerTests.swift -> CheekyPintTests/
            .deletingLastPathComponent() // CheekyPintTests/ -> repo root

        let feedDirectory = repoRoot.appendingPathComponent("CheekyPint/Features/Feed")
        let feedFiles = try FileManager.default.contentsOfDirectory(
            at: feedDirectory, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        // An empty scan would pass for the wrong reason — silently checking nothing. Fail loudly
        // instead if the directory ever turns up empty.
        XCTAssertFalse(feedFiles.isEmpty, "expected to find .swift files under \(feedDirectory.path)")

        let placeCompleter = repoRoot.appendingPathComponent("CheekyPint/Core/Location/PlaceCompleter.swift")
        let filesToScan = feedFiles + [placeCompleter]

        let forbiddenPatterns = [
            "import CoreLocation",
            "CLLocationManager(",
            ": CLLocationManager",
            "LocationService(",
            ": LocationService",
            "requestWhenInUseAuthorization(",
            "completer.region",
            ".region =",
            "CLLocationCoordinate2D",
            "CLLocation",
        ]

        for fileURL in filesToScan {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            for pattern in forbiddenPatterns {
                XCTAssertFalse(source.contains(pattern),
                               "\(fileURL.lastPathComponent) must not depend on `\(pattern)` — " +
                               "this picker must never request location permission")
            }
        }
    }
}
