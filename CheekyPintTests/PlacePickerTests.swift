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

    func testLabelIsClampedToTheServerLimit() {
        let long = String(repeating: "a", count: 200)
        let place = PlacePickerSheet.freeTextPlace(from: long)
        XCTAssertEqual(place?.label.count, 80,
                       "server truncates place_label at 80; clamp before sending")
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
    /// instantiation, a leading `: ` for a type annotation — which only appear in real usage, not
    /// in prose. Concretely: `LocationService()`, `CLLocationManager()`, `import CoreLocation`,
    /// and `.requestWhenInUseAuthorization()` all still trip it; a sentence mentioning
    /// "LocationService" or "CLLocationManager" by name does not. It also checks both files the
    /// requirement actually names (the brief's version only checked `PlacePickerSheet.swift`, but
    /// the constraint is stated for `PlacePickerSheet` *and* `PlaceCompleter`).
    ///
    /// Concrete input that flips this test: reintroduce `@State private var location =
    /// LocationService()` into `PlacePickerSheet` (exactly what `PubPickerView` has) — that
    /// contains the literal text `LocationService(` and fails immediately.
    func testNeitherFileDependsOnLocationPermissionAPIs() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PlacePickerTests.swift -> CheekyPintTests/
            .deletingLastPathComponent() // CheekyPintTests/ -> repo root
        let relativePaths = [
            "CheekyPint/Features/Feed/PlacePickerSheet.swift",
            "CheekyPint/Core/Location/PlaceCompleter.swift",
        ]
        let forbiddenPatterns = [
            "import CoreLocation",
            "CLLocationManager(",
            ": CLLocationManager",
            "LocationService(",
            ": LocationService",
            "requestWhenInUseAuthorization(",
        ]
        for relativePath in relativePaths {
            let fileURL = repoRoot.appendingPathComponent(relativePath)
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            for pattern in forbiddenPatterns {
                XCTAssertFalse(source.contains(pattern),
                               "\(relativePath) must not depend on `\(pattern)` — this picker " +
                               "must never request location permission")
            }
        }
    }
}
