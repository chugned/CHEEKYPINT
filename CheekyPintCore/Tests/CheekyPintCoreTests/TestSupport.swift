import Foundation
import XCTest
@testable import CheekyPintCore

enum Fixtures {
    /// A fixed instant from an ISO-8601 string with explicit offset, e.g. "2025-01-01T00:30:00Z".
    static func instant(_ iso: String, file: StaticString = #filePath, line: UInt = #line) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: iso) { return date }
        // Retry allowing fractional seconds.
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: iso) else {
            XCTFail("Bad ISO date: \(iso)", file: file, line: line)
            return Date(timeIntervalSince1970: 0)
        }
        return date
    }

    /// A calendar pinned to a locale + time zone, matching `Profile.resolvedCalendar`.
    static func calendar(locale: String, timeZone: String) -> Calendar {
        Profile(id: UUID(), displayName: "Test", timezone: timeZone, locale: locale).resolvedCalendar
    }

    static func profile(
        id: UUID = UUID(),
        name: String = "Test",
        locale: String = "en_GB",
        timeZone: String = "Europe/Vienna"
    ) -> Profile {
        Profile(id: id, displayName: name, timezone: timeZone, locale: locale)
    }

    /// A pint entry with sensible defaults; override only what a test cares about.
    static func entry(
        id: UUID = UUID(),
        userId: UUID = UUID(),
        at occurredAt: Date,
        serving: ServingType = .pint,
        volumeMl: Double? = nil,
        alcoholFree: Bool = false,
        deletedAt: Date? = nil
    ) -> PintEntry {
        PintEntry(
            id: id,
            userId: userId,
            occurredAt: occurredAt,
            servingType: serving,
            volumeMl: volumeMl,
            alcoholFree: alcoholFree,
            idempotencyKey: IdempotencyKey.generate().rawValue,
            deletedAt: deletedAt
        )
    }
}
