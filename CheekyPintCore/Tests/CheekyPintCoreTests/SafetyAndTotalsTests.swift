import XCTest
@testable import CheekyPintCore

final class WelfareMonitorTests: XCTestCase {
    private let monitor = WelfareMonitor(windowSeconds: 90 * 60, threshold: 3)
    private let now = Fixtures.instant("2025-06-01T20:00:00Z")

    func testCheersForFirstFewDrinks() {
        XCTAssertEqual(monitor.tone(forEntryAt: now, recentEntryDates: []), .cheers)
        let oneRecent = [now.addingTimeInterval(-30 * 60)]
        XCTAssertEqual(monitor.tone(forEntryAt: now, recentEntryDates: oneRecent), .cheers)
    }

    func testWelfareOnceThresholdReachedWithinWindow() {
        // Two recent + this one = 3 within 90 minutes → welfare.
        let recent = [now.addingTimeInterval(-20 * 60), now.addingTimeInterval(-50 * 60)]
        XCTAssertEqual(monitor.tone(forEntryAt: now, recentEntryDates: recent), .welfare)
        XCTAssertEqual(monitor.message(forEntryAt: now, recentEntryDates: recent), WelfareMonitor.welfareMessage)
    }

    func testOldEntriesOutsideWindowDoNotTriggerWelfare() {
        let recent = [now.addingTimeInterval(-100 * 60), now.addingTimeInterval(-120 * 60)]
        XCTAssertEqual(monitor.tone(forEntryAt: now, recentEntryDates: recent), .cheers)
    }
}

final class AbuseDetectorTests: XCTestCase {
    private let detector = AbuseDetector(minInterval: 60, maxPerHour: 12)
    private let now = Fixtures.instant("2025-06-01T20:00:00Z")

    func testFlagsEntryTooSoonAfterPrevious() {
        let flags = detector.flags(forEntryAt: now, recentEntryDates: [now.addingTimeInterval(-15)])
        XCTAssertEqual(flags, [.tooSoonAfterPrevious(interval: 15)])
        XCTAssertTrue(detector.isImplausible(forEntryAt: now, recentEntryDates: [now.addingTimeInterval(-15)]))
    }

    func testFlagsTooManyPerHour() {
        // 12 entries in the last hour + this one = 13 > 12.
        let recent = (1...12).map { now.addingTimeInterval(-Double($0) * 4 * 60) } // spaced 4 min apart
        let flags = detector.flags(forEntryAt: now, recentEntryDates: recent)
        XCTAssertTrue(flags.contains(.tooManyPerHour(count: 13)))
    }

    func testPlausibleCadenceHasNoFlags() {
        let recent = [now.addingTimeInterval(-30 * 60), now.addingTimeInterval(-70 * 60)]
        XCTAssertTrue(detector.flags(forEntryAt: now, recentEntryDates: recent).isEmpty)
    }
}

final class PersonalTotalsCalculatorTests: XCTestCase {
    func testAggregatesAllPeriodsForCurrentUser() {
        let profile = Fixtures.profile(locale: "en_GB", timeZone: "Europe/London")
        let now = Fixtures.instant("2025-01-15T20:00:00Z") // Wed, week Mon13–Mon20, Jan, 2025

        let entries = [
            Fixtures.entry(at: Fixtures.instant("2025-01-15T18:00:00Z")), // this week/month/year
            Fixtures.entry(at: Fixtures.instant("2025-01-06T18:00:00Z")), // prior week, this month/year
            Fixtures.entry(at: Fixtures.instant("2024-12-30T18:00:00Z"))  // last year
        ]

        let totals = PersonalTotalsCalculator(profile: profile).totals(entries: entries, now: now, session: nil)
        XCTAssertNil(totals.session, "no active session → no session total")
        XCTAssertEqual(totals.week.recordedCount, 1)
        XCTAssertEqual(totals.month.recordedCount, 2)
        XCTAssertEqual(totals.year.recordedCount, 2)
    }

    func testSessionTotalWhenActive() {
        let profile = Fixtures.profile(locale: "en_GB", timeZone: "Europe/London")
        let start = Fixtures.instant("2025-01-15T18:00:00Z")
        let now = Fixtures.instant("2025-01-15T21:00:00Z")
        let session = PubSession(id: UUID(), hostUserId: profile.id, status: .active, startedAt: start)

        let entries = [
            Fixtures.entry(at: Fixtures.instant("2025-01-15T18:30:00Z")), // in session
            Fixtures.entry(at: Fixtures.instant("2025-01-15T17:00:00Z"))  // before session start
        ]
        let totals = PersonalTotalsCalculator(profile: profile).totals(entries: entries, now: now, session: session)
        XCTAssertEqual(totals.session?.recordedCount, 1)
    }
}

final class PrivacySettingsTests: XCTestCase {
    func testRecommendedDefaultsMatchOnboardingSpec() {
        let settings = PrivacySettings.recommendedDefault(userId: UUID())
        XCTAssertEqual(settings.profileVisibility, .friends)
        XCTAssertEqual(settings.cityVisibility, .private)          // city off by default
        XCTAssertEqual(settings.favouritePubsVisibility, .private) // favourite pubs off by default
        XCTAssertEqual(settings.weeklyTotalVisibility, .friends)   // totals visible to friends
        XCTAssertEqual(settings.sharedSessionsVisibility, .friends)// recent shared sessions on
    }
}
