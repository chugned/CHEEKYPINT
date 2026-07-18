import XCTest
@testable import CheekyPintCore

/// The riskiest logic in the app: calendar-, locale-, time-zone-, and DST-aware period math.
final class PeriodCalculatorTests: XCTestCase {

    // MARK: First weekday follows locale

    func testWeekStartsMondayInGreatBritain() {
        let calendar = Fixtures.calendar(locale: "en_GB", timeZone: "Europe/London")
        XCTAssertEqual(calendar.firstWeekday, 2, "en_GB weeks start on Monday")

        // Wednesday 15 Jan 2025.
        let reference = Fixtures.instant("2025-01-15T12:00:00Z")
        let week = PeriodCalculator(calendar: calendar).week(containing: reference)!

        let startComponents = calendar.dateComponents([.weekday], from: week.start)
        XCTAssertEqual(startComponents.weekday, 2) // Monday
        // The week [Mon 13 Jan 00:00, Mon 20 Jan 00:00).
        XCTAssertEqual(week.start, Fixtures.instant("2025-01-13T00:00:00Z"))
        XCTAssertEqual(week.end, Fixtures.instant("2025-01-20T00:00:00Z"))
    }

    func testWeekStartsSundayInUnitedStates() {
        let calendar = Fixtures.calendar(locale: "en_US", timeZone: "America/New_York")
        XCTAssertEqual(calendar.firstWeekday, 1, "en_US weeks start on Sunday")

        let reference = Fixtures.instant("2025-01-15T17:00:00Z") // Wed noon EST
        let week = PeriodCalculator(calendar: calendar).week(containing: reference)!
        let startComponents = calendar.dateComponents([.weekday], from: week.start)
        XCTAssertEqual(startComponents.weekday, 1) // Sunday
    }

    // MARK: Month & year windows

    func testMonthWindow() {
        let calendar = Fixtures.calendar(locale: "en_GB", timeZone: "Europe/London")
        let reference = Fixtures.instant("2025-02-10T09:00:00Z")
        let month = PeriodCalculator(calendar: calendar).month(containing: reference)!
        XCTAssertEqual(month.start, Fixtures.instant("2025-02-01T00:00:00Z"))
        XCTAssertEqual(month.end, Fixtures.instant("2025-03-01T00:00:00Z"))
    }

    func testYearWindowIsLeapYearAware() {
        let calendar = Fixtures.calendar(locale: "en_GB", timeZone: "Europe/London")
        let reference = Fixtures.instant("2024-06-15T00:00:00Z") // 2024 is a leap year
        let year = PeriodCalculator(calendar: calendar).year(containing: reference)!
        XCTAssertEqual(year.start, Fixtures.instant("2024-01-01T00:00:00Z"))
        XCTAssertEqual(year.end, Fixtures.instant("2025-01-01T00:00:00Z"))
        // 366 days in 2024.
        XCTAssertEqual(year.duration, 366 * 86_400, accuracy: 1)
    }

    // MARK: Daylight saving

    func testMonthDurationAccountsForSpringForwardDST() {
        // Europe/Vienna springs forward on 30 March 2025 (02:00 → 03:00), losing one hour.
        let calendar = Fixtures.calendar(locale: "de_AT", timeZone: "Europe/Vienna")
        let reference = Fixtures.instant("2025-03-15T09:00:00Z")
        let month = PeriodCalculator(calendar: calendar).month(containing: reference)!

        // March has 31 days but this March is one hour short because of DST.
        let expected = TimeInterval(31 * 24 - 1) * 3600
        XCTAssertEqual(month.duration, expected, accuracy: 1,
                       "March 2025 in Vienna must be 31 days minus one DST hour")
        // Boundaries are local midnights, not UTC midnights.
        XCTAssertEqual(month.start, Fixtures.instant("2025-02-28T23:00:00Z")) // 1 Mar 00:00 +01:00
        XCTAssertEqual(month.end, Fixtures.instant("2025-03-31T22:00:00Z"))   // 1 Apr 00:00 +02:00
    }

    // MARK: Time zone changes which calendar period an instant belongs to

    func testSameInstantFallsInDifferentYearsByTimeZone() {
        let instant = Fixtures.instant("2025-01-01T00:30:00Z")

        let losAngeles = Fixtures.calendar(locale: "en_US", timeZone: "America/Los_Angeles")
        let vienna = Fixtures.calendar(locale: "de_AT", timeZone: "Europe/Vienna")

        let laYear = PeriodCalculator(calendar: losAngeles).year(containing: instant)!
        let viennaYear = PeriodCalculator(calendar: vienna).year(containing: instant)!

        // In LA it is still 2024 (16:30, Dec 31); in Vienna it is 2025 (01:30, Jan 1).
        XCTAssertEqual(laYear.start, Fixtures.instant("2024-01-01T08:00:00Z"))  // 1 Jan 2024 00:00 PST
        XCTAssertTrue(laYear.contains(instant))
        XCTAssertEqual(viennaYear.start, Fixtures.instant("2024-12-31T23:00:00Z")) // 1 Jan 2025 00:00 CET
        XCTAssertTrue(viennaYear.contains(instant))
    }

    // MARK: Session windows

    func testSessionWindowUsesNowWhileActive() {
        let calendar = Fixtures.calendar(locale: "en_GB", timeZone: "Europe/London")
        let start = Fixtures.instant("2025-05-01T18:00:00Z")
        let now = Fixtures.instant("2025-05-01T20:30:00Z")
        let session = PubSession(id: UUID(), hostUserId: UUID(), status: .active, startedAt: start, endedAt: nil)

        let window = PeriodCalculator(calendar: calendar)
            .period(for: .session, containing: now, session: session, now: now)!
        XCTAssertEqual(window.start, start)
        XCTAssertEqual(window.end, now)
    }

    func testSessionPeriodIsNilWithoutSession() {
        let calendar = Fixtures.calendar(locale: "en_GB", timeZone: "Europe/London")
        let window = PeriodCalculator(calendar: calendar)
            .period(for: .session, containing: Date(), session: nil)
        XCTAssertNil(window)
    }
}
