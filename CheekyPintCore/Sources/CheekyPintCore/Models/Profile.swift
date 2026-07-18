import Foundation

/// A user profile. Column names map 1:1 to the `profiles` table via
/// `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase`.
public struct Profile: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var displayName: String
    public var username: String?
    public var bio: String?
    public var avatarPath: String?
    /// Broad, user-entered location only (e.g. "Graz, Austria"). Never a street address.
    public var city: String?
    public var countryCode: String?
    public var legalAgeConfirmedAt: Date?
    /// IANA identifier, e.g. "Europe/Vienna". Column: `timezone`.
    public var timezone: String
    /// BCP-47 identifier, e.g. "en_GB". Column: `locale`.
    public var locale: String
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID,
        displayName: String,
        username: String? = nil,
        bio: String? = nil,
        avatarPath: String? = nil,
        city: String? = nil,
        countryCode: String? = nil,
        legalAgeConfirmedAt: Date? = nil,
        timezone: String = TimeZone.current.identifier,
        locale: String = Locale.current.identifier,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.username = username
        self.bio = bio
        self.avatarPath = avatarPath
        self.city = city
        self.countryCode = countryCode
        self.legalAgeConfirmedAt = legalAgeConfirmedAt
        self.timezone = timezone
        self.locale = locale
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    /// Whether the user has confirmed they meet the legal drinking age (master prompt §3).
    public var hasConfirmedLegalAge: Bool { legalAgeConfirmedAt != nil }

    /// The `Calendar` used for all period math for this user — locale + time zone aware
    /// so week/month/year boundaries follow the user's real-world settings (§9, §15).
    ///
    /// We start from the *locale's* calendar (not a forced Gregorian one) so that
    /// `firstWeekday` and `minimumDaysInFirstWeek` already reflect the region's
    /// convention — Monday in en_GB, Sunday in en_US — then pin the time zone.
    public var resolvedCalendar: Calendar {
        let loc = Locale(identifier: locale)
        var calendar = loc.calendar
        calendar.locale = loc
        calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        return calendar
    }
}
