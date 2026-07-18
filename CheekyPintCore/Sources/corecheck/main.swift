import Foundation
import CheekyPintCore

// A tiny, XCTest-free verification harness. It mirrors the highest-risk assertions from the
// XCTest suite so the domain logic can be verified on a toolchain without Xcode.
// Run with: `swift run corecheck`. Exits non-zero if any check fails.

private var checks = 0
private var failures = 0

@MainActor
private func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("  ❌ [line \(line)] \(message)")
    }
}

@MainActor
private func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String, line: UInt = #line) {
    checks += 1
    if lhs != rhs {
        failures += 1
        print("  ❌ [line \(line)] \(message): \(lhs) != \(rhs)")
    }
}

@MainActor
private func expectClose(_ lhs: Double, _ rhs: Double, _ accuracy: Double, _ message: String, line: UInt = #line) {
    checks += 1
    if abs(lhs - rhs) > accuracy {
        failures += 1
        print("  ❌ [line \(line)] \(message): \(lhs) !≈ \(rhs)")
    }
}

@MainActor
private func section(_ name: String, _ body: () -> Void) {
    print("• \(name)")
    body()
}

// MARK: - Helpers

func instant(_ iso: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: iso) ?? Date(timeIntervalSince1970: 0)
}

func calendar(_ locale: String, _ tz: String) -> Calendar {
    Profile(id: UUID(), displayName: "T", timezone: tz, locale: locale).resolvedCalendar
}

func entry(at date: Date, serving: ServingType = .pint, volumeMl: Double? = nil,
           alcoholFree: Bool = false, deletedAt: Date? = nil) -> PintEntry {
    PintEntry(id: UUID(), userId: UUID(), occurredAt: date, servingType: serving,
              volumeMl: volumeMl, alcoholFree: alcoholFree,
              idempotencyKey: IdempotencyKey.generate().rawValue, deletedAt: deletedAt)
}

// MARK: - Checks

section("Period math: locale first-weekday") {
    let gb = calendar("en_GB", "Europe/London")
    expectEqual(gb.firstWeekday, 2, "en_GB week starts Monday")
    let us = calendar("en_US", "America/New_York")
    expectEqual(us.firstWeekday, 1, "en_US week starts Sunday")

    let week = PeriodCalculator(calendar: gb).week(containing: instant("2025-01-15T12:00:00Z"))!
    expectEqual(week.start, instant("2025-01-13T00:00:00Z"), "GB week starts Mon 13 Jan")
    expectEqual(week.end, instant("2025-01-20T00:00:00Z"), "GB week ends Mon 20 Jan")
}

section("Period math: month, leap year, DST") {
    let gb = PeriodCalculator(calendar: calendar("en_GB", "Europe/London"))
    let feb = gb.month(containing: instant("2025-02-10T09:00:00Z"))!
    expectEqual(feb.start, instant("2025-02-01T00:00:00Z"), "Feb starts 1 Feb")
    expectEqual(feb.end, instant("2025-03-01T00:00:00Z"), "Feb ends 1 Mar")

    let year2024 = gb.year(containing: instant("2024-06-15T00:00:00Z"))!
    expectClose(year2024.duration, 366 * 86_400, 1, "2024 is a leap year (366 days)")

    let vienna = PeriodCalculator(calendar: calendar("de_AT", "Europe/Vienna"))
    let march = vienna.month(containing: instant("2025-03-15T09:00:00Z"))!
    expectClose(march.duration, Double(31 * 24 - 1) * 3600, 1, "March 2025 Vienna loses a DST hour")
    expectEqual(march.start, instant("2025-02-28T23:00:00Z"), "Vienna Mar starts at local midnight (+01:00)")
    expectEqual(march.end, instant("2025-03-31T22:00:00Z"), "Vienna Mar ends at local midnight (+02:00)")
}

section("Period math: same instant, different year by time zone") {
    let moment = instant("2025-01-01T00:30:00Z")
    let la = PeriodCalculator(calendar: calendar("en_US", "America/Los_Angeles")).year(containing: moment)!
    let vienna = PeriodCalculator(calendar: calendar("de_AT", "Europe/Vienna")).year(containing: moment)!
    expect(la.contains(moment), "instant is in LA's year window")
    expectEqual(la.start, instant("2024-01-01T08:00:00Z"), "LA year is 2024 (still Dec 31 locally)")
    expectEqual(vienna.start, instant("2024-12-31T23:00:00Z"), "Vienna year is 2025")
}

section("Counting: window, alcohol-free, soft delete") {
    let gb = PeriodCalculator(calendar: calendar("en_GB", "Europe/London"))
    let window = gb.week(containing: instant("2025-01-15T12:00:00Z"))!
    let at = instant("2025-01-15T18:00:00Z")

    let inOut = [
        entry(at: instant("2025-01-13T00:00:00Z")), // inclusive lower bound
        entry(at: at),
        entry(at: instant("2025-01-20T00:00:00Z")), // exclusive upper bound → out
        entry(at: instant("2025-01-12T23:59:59Z"))  // before → out
    ]
    expectEqual(PintCounter().total(of: inOut, in: window).recordedCount, 2, "half-open window counts 2")

    let mixed = [entry(at: at, alcoholFree: false), entry(at: at, alcoholFree: true)]
    expectEqual(PintCounter(rule: .default).total(of: mixed, in: window).recordedCount, 1, "alcohol-free excluded by default")
    expectEqual(PintCounter(rule: .allDrinks).total(of: mixed, in: window).recordedCount, 2, "allDrinks includes alcohol-free")

    let deleted = [entry(at: at), entry(at: at, deletedAt: at)]
    expectEqual(PintCounter(rule: .allDrinks).total(of: deleted, in: window).recordedCount, 1, "soft-deleted never counts")

    let servings = [entry(at: at, serving: .pint), entry(at: at, serving: .halfPint), entry(at: at, serving: .ml500)]
    let total = PintCounter(rule: .ukPintEquivalent).total(of: servings, in: window)
    expectClose(total.standardServings, 1.0 + 0.5 + 500 / 568.26, 0.0001, "standard servings sum")
}

section("Leaderboard: ranking, ties, private, preview") {
    func participant(_ name: String, _ count: Int?, me: Bool = false) -> LeaderboardParticipant {
        LeaderboardParticipant(id: UUID(), displayName: name, isCurrentUser: me,
                               total: count.map { PintTotal(recordedCount: $0, standardServings: Double($0)) })
    }
    let builder = LeaderboardBuilder()

    let ranked = builder.build([participant("Alice", 2), participant("Bob", 5), participant("Cara", 3)])
    expectEqual(ranked.map(\.displayName), ["Bob", "Cara", "Alice"], "descending order")
    expectEqual(ranked.compactMap(\.rank), [1, 2, 3], "ranks 1,2,3")

    let ties = builder.build([participant("Bob", 5), participant("Cara", 5), participant("Alice", 1)])
    expectEqual(ties.compactMap(\.rank), [1, 1, 3], "competition ranking with skip")

    let withPrivate = builder.build([participant("Bob", 5), participant("Zoe", nil), participant("Alice", 2)])
    expectEqual(withPrivate.map(\.displayName), ["Bob", "Alice", "Zoe"], "private row goes last")
    expect(withPrivate[2].isPrivate && withPrivate[2].rank == nil, "private row has no rank")

    let preview = builder.preview([
        participant("Bob", 9), participant("Cara", 8), participant("Dan", 7),
        participant("Eve", 6), participant("Me", 1, me: true)
    ], topCount: 3)
    expectEqual(preview.count, 4, "top 3 + current user")
    expect(preview.last!.isCurrentUser && preview.last!.rank == 5, "current user appended with real rank")
}

section("Privacy: block overrides, placeholders, previews") {
    let resolver = VisibilityResolver()
    var settings = PrivacySettings.recommendedDefault(userId: UUID())

    for field: ProfileField in [.displayName, .avatar, .city, .total(.week)] {
        expectEqual(resolver.decision(for: field, relationship: .blocked, settings: settings), .hidden, "block hides \(field)")
    }
    expectEqual(resolver.decision(for: .total(.week), relationship: .friend, settings: settings), .visible, "friend sees shared total")
    settings.weeklyTotalVisibility = .private
    expectEqual(resolver.decision(for: .total(.week), relationship: .friend, settings: settings), .privatePlaceholder, "hidden total → Private")
    expectEqual(resolver.decision(for: .city, relationship: .friend, settings: settings), .hidden, "hidden city disappears")
    expectEqual(resolver.decision(for: .avatar, relationship: .pendingRequest, settings: settings), .visible, "pending sees avatar preview")
    expectEqual(resolver.decision(for: .city, relationship: .pendingRequest, settings: settings), .hidden, "pending can't see city")
    expect(!resolver.canViewProfile(relationship: .stranger, profileVisibility: .friends), "stranger can't open profile")
}

section("Validation & sanitising") {
    let validator = UsernameValidator()
    expectEqual(try? validator.validate("  BarnabY_01 ").get(), "barnaby_01", "normalises username")
    expect(!validator.isValid("admin"), "reserved username rejected")
    expect(!validator.isValid("bad-name"), "invalid chars rejected")
    expect(!validator.isValid("1abc"), "must start with a letter")

    let sanitizer = ProfileTextSanitizer()
    expectEqual(sanitizer.sanitizeDisplayName("Ne\u{200B}d\u{202E}im"), "Nedim", "strips zero-width/bidi")
    expectEqual(sanitizer.sanitizeDisplayName("  The   Kings\tArms  "), "The Kings Arms", "collapses whitespace")
    let emoji = sanitizer.sanitizeDisplayName(String(repeating: "🍺", count: 60))
    expectEqual(emoji.count, ProfileTextSanitizer.displayNameMaxLength, "truncates by grapheme")
}

section("QR tokens & deep links") {
    let token = FriendToken.generate()
    expectEqual(token.rawValue.count, 43, "32-byte token → 43 base64url chars")
    expect(!token.rawValue.contains("+") && !token.rawValue.contains("/") && !token.rawValue.contains("="), "URL-safe")
    expectEqual(Set((0..<200).map { _ in FriendToken.generate().rawValue }).count, 200, "tokens unique")
    expect(FriendToken(rawValue: "abc") == nil, "short token rejected")

    let parser = DeepLinkParser()
    expectEqual(parser.parse(parser.addFriendURL(token)), .addFriend(token), "friend link round-trips")
    expectEqual(parser.parse(parser.joinSessionURL(token, universal: true)), .joinSession(token), "universal session link round-trips")
    expect(parser.parse(URL(string: "https://evil.example/friend/\(token.rawValue)")!) == nil, "foreign host rejected")

    let code = ShortFriendCode.generate()
    expectEqual(code.rawValue.count, 8, "short code length")
    expect(ShortFriendCode(rawValue: "O0IL1234") == nil, "ambiguous glyphs rejected")
}

section("Welfare & abuse cadence") {
    let now = instant("2025-06-01T20:00:00Z")
    let monitor = WelfareMonitor()
    expectEqual(monitor.tone(forEntryAt: now, recentEntryDates: []), .cheers, "first drink → cheers")
    expectEqual(monitor.tone(forEntryAt: now, recentEntryDates: [now.addingTimeInterval(-1200), now.addingTimeInterval(-3000)]), .welfare, "3 in window → welfare")
    expectEqual(monitor.tone(forEntryAt: now, recentEntryDates: [now.addingTimeInterval(-6000), now.addingTimeInterval(-7200)]), .cheers, "old entries don't trigger")

    let detector = AbuseDetector()
    expect(detector.isImplausible(forEntryAt: now, recentEntryDates: [now.addingTimeInterval(-15)]), "15s gap flagged")
    expect(!detector.isImplausible(forEntryAt: now, recentEntryDates: [now.addingTimeInterval(-1800)]), "30min gap fine")
}

// MARK: - Summary

print("")
if failures == 0 {
    print("✅ corecheck passed: \(checks) checks")
    exit(0)
} else {
    print("❌ corecheck FAILED: \(failures) of \(checks) checks failed")
    exit(1)
}
