import XCTest
@testable import CheekyPintCore

final class PintCounterTests: XCTestCase {
    private let calendar = Fixtures.calendar(locale: "en_GB", timeZone: "Europe/London")

    private func weekWindow(around iso: String) -> DatePeriod {
        PeriodCalculator(calendar: calendar).week(containing: Fixtures.instant(iso))!
    }

    func testCountsOnlyEntriesInsideWindow() {
        let window = weekWindow(around: "2025-01-15T12:00:00Z") // Mon 13 – Mon 20
        let entries = [
            Fixtures.entry(at: Fixtures.instant("2025-01-13T00:00:00Z")), // inside (lower bound inclusive)
            Fixtures.entry(at: Fixtures.instant("2025-01-16T21:00:00Z")), // inside
            Fixtures.entry(at: Fixtures.instant("2025-01-20T00:00:00Z")), // excluded (upper bound exclusive)
            Fixtures.entry(at: Fixtures.instant("2025-01-12T23:59:59Z"))  // excluded (before window)
        ]
        let total = PintCounter().total(of: entries, in: window)
        XCTAssertEqual(total.recordedCount, 2)
    }

    func testAlcoholFreeExcludedByDefaultButCountedByAllDrinksRule() {
        let window = weekWindow(around: "2025-01-15T12:00:00Z")
        let at = Fixtures.instant("2025-01-15T18:00:00Z")
        let entries = [
            Fixtures.entry(at: at, alcoholFree: false),
            Fixtures.entry(at: at, alcoholFree: true)
        ]
        XCTAssertEqual(PintCounter(rule: .default).total(of: entries, in: window).recordedCount, 1)
        XCTAssertEqual(PintCounter(rule: .allDrinks).total(of: entries, in: window).recordedCount, 2)
    }

    func testSoftDeletedEntriesNeverCount() {
        let window = weekWindow(around: "2025-01-15T12:00:00Z")
        let at = Fixtures.instant("2025-01-15T18:00:00Z")
        let entries = [
            Fixtures.entry(at: at),
            Fixtures.entry(at: at, deletedAt: Fixtures.instant("2025-01-15T18:05:00Z"))
        ]
        XCTAssertEqual(PintCounter(rule: .default).total(of: entries, in: window).recordedCount, 1)
        XCTAssertEqual(PintCounter(rule: .allDrinks).total(of: entries, in: window).recordedCount, 1)
    }

    func testStandardServingsSumsVolumeRelativeToUKPint() {
        let window = weekWindow(around: "2025-01-15T12:00:00Z")
        let at = Fixtures.instant("2025-01-15T18:00:00Z")
        let entries = [
            Fixtures.entry(at: at, serving: .pint),      // 568.26 ml → 1.0
            Fixtures.entry(at: at, serving: .halfPint),  // 284.13 ml → 0.5
            Fixtures.entry(at: at, serving: .ml500)      // 500 ml → ~0.8799
        ]
        let total = PintCounter(rule: .ukPintEquivalent).total(of: entries, in: window)
        XCTAssertEqual(total.recordedCount, 3)
        XCTAssertEqual(total.standardServings, 1.0 + 0.5 + (500 / 568.26), accuracy: 0.0001)
        XCTAssertEqual(total.displayValue(for: .ukPintEquivalent), total.standardServings, accuracy: 0.0001)
    }

    func testCustomVolumeCountsAsEntryAndContributesToStandardServings() {
        let window = weekWindow(around: "2025-01-15T12:00:00Z")
        let at = Fixtures.instant("2025-01-15T18:00:00Z")
        let entry = Fixtures.entry(at: at, serving: .custom, volumeMl: 1136.52) // two UK pints
        let total = PintCounter(rule: .ukPintEquivalent).total(of: [entry], in: window)
        XCTAssertEqual(total.recordedCount, 1)
        XCTAssertEqual(total.standardServings, 2.0, accuracy: 0.0001)
    }

    func testNilWindowReturnsZero() {
        XCTAssertEqual(PintCounter().total(of: [Fixtures.entry(at: Date())], in: nil), .zero)
    }
}
