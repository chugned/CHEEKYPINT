import XCTest
import CheekyPintCore
@testable import CheekyPint

/// `BroadLocationField`'s pure logic: the street-level filter, and — the assertion this whole
/// task is really about — the structural reduction that keeps a tapped suggestion from ever
/// writing a street address into `profiles.city`
/// (`supabase/migrations/20260101000200_core_tables.sql`: "BROAD, user-entered location only —
/// never a street address, never inferred from activity"). See
/// `PlacePickerTests.testNoScannedFileDependsOnLocationPermissionAPIs` for this field's location-
/// permission guard, which lives there because it scans this field's file by name alongside
/// `PlaceCompleter.swift` and the `Features/Onboarding`/`Features/Settings` directories.
final class BroadLocationFieldTests: XCTestCase {

    // MARK: - isLikelyStreetLevel (the list filter — a courtesy, not the guarantee)

    /// The concrete inputs that flip this test either way: a house number front-loaded ("123 Main
    /// Street", the common English shape) and back-loaded ("Hauptplatz 1", the shape this task's
    /// own worked example uses) both trip it; an ordinary place name with no digit does not.
    func testIsLikelyStreetLevelFlagsADigitAnywhereInTheTitle() {
        XCTAssertTrue(BroadLocationField.isLikelyStreetLevel(title: "123 Main Street"),
                      "a leading house number must be treated as street-level")
        XCTAssertTrue(BroadLocationField.isLikelyStreetLevel(title: "Hauptplatz 1"),
                      "a trailing house number (the German/Austrian ordering) must also be caught")
        XCTAssertFalse(BroadLocationField.isLikelyStreetLevel(title: "Graz"),
                       "a bare place name has no digit and must not be filtered")
        XCTAssertFalse(BroadLocationField.isLikelyStreetLevel(title: "Graz, Austria"),
                       "a place name with a trailing country still has no digit")
    }

    // MARK: - reduceToBroadArea — the structural guarantee

    /// The assertion that matters most in this whole task: a street-level selection must reduce
    /// to a broad locality. `locality`/`administrativeArea`/`country` here are exactly what a
    /// resolved `MKPlacemark` would carry for this task's own worked example — "Hauptplatz 1,
    /// Graz, Steiermark, Austria" — except `thoroughfare` ("Hauptplatz") and `subThoroughfare`
    /// ("1") are never passed in at all, because `reduceToBroadArea` has no parameter for either.
    ///
    /// The concrete input that flips this test: give `reduceToBroadArea` a `thoroughfare`
    /// parameter and fold it into the joined result (the plausible-looking "fix" a future edit
    /// might make to show more detail on screen) — the `XCTAssertEqual` against the exact string
    /// `"Graz, Austria"` fails the moment "Hauptplatz" joins it, and the two `XCTAssertFalse
    /// (...contains...)` lines below fail even if the exact-equality assertion were loosened or
    /// removed. Verified by hand — see this task's report for the verbatim failure text.
    func testStreetLevelSelectionReducesToABroadLocality() {
        let result = BroadLocationField.reduceToBroadArea(
            locality: "Graz",
            administrativeArea: "Steiermark",
            country: "Austria"
        )

        XCTAssertEqual(result, "Graz, Austria",
                       "administrative area is a fallback for locality, not appended alongside it")
        XCTAssertFalse(result.contains("Hauptplatz"), "thoroughfare must never reach the stored value")
        XCTAssertFalse(result.contains("1"), "sub-thoroughfare (house number) must never reach the stored value")
    }

    /// Administrative area only surfaces when there is no locality to prefer — a search that
    /// resolves to a region rather than a city (a placemark with no `locality` at all).
    func testReduceToBroadAreaFallsBackToAdministrativeAreaWhenLocalityIsMissing() {
        let result = BroadLocationField.reduceToBroadArea(
            locality: nil, administrativeArea: "Styria", country: "Austria")
        XCTAssertEqual(result, "Styria, Austria",
                       "with no locality, administrative area must still contribute")
    }

    /// Blank (whitespace-only) components must be treated as absent, not joined in as empty
    /// segments — otherwise a placemark with an empty-string `locality` would produce ", Austria"
    /// (a leading comma-space with nothing before it).
    func testReduceToBroadAreaTreatsBlankComponentsAsAbsent() {
        let result = BroadLocationField.reduceToBroadArea(
            locality: "   ", administrativeArea: "Vienna", country: "  ")
        XCTAssertEqual(result, "Vienna", "a blank locality/country must not leave stray separators")
    }

    /// A placemark with nothing broad-safe to offer (no locality, no administrative area, no
    /// country) must reduce to an empty string rather than crash or emit a stray fragment — this
    /// is what lets `selectSuggestion` treat emptiness as "resolution gave us nothing usable" and
    /// leave `city` untouched instead of ever falling back to the completion's own raw text.
    func testReduceToBroadAreaWithNothingUsableIsEmpty() {
        XCTAssertEqual(
            BroadLocationField.reduceToBroadArea(locality: nil, administrativeArea: nil, country: nil), "")
    }

    /// A single real component must join with nothing else — no stray leading/trailing comma.
    func testReduceToBroadAreaWithOnlyLocalityHasNoStrayPunctuation() {
        XCTAssertEqual(
            BroadLocationField.reduceToBroadArea(locality: "Graz", administrativeArea: nil, country: nil), "Graz")
    }

    /// The composed value must still be well-behaved once it goes through the same
    /// `ProfileTextSanitizer.sanitizeCity` clamp every other write to this column uses — no second
    /// limit invented for suggestion-derived values (the task's own explicit requirement). An
    /// ordinary reduced value must pass through unchanged.
    func testReducedValueSurvivesTheSharedCityClamp() {
        let reduced = BroadLocationField.reduceToBroadArea(locality: "Graz", administrativeArea: nil, country: "Austria")
        XCTAssertEqual(ProfileTextSanitizer().sanitizeCity(reduced), "Graz, Austria",
                       "an ordinary reduced value must pass the shared clamp unchanged")
    }
}
