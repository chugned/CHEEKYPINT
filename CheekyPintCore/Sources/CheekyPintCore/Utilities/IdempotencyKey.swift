import Foundation

/// A per-submission idempotency key. Generated once when the confirmation sheet opens and
/// reused for every retry of that same logical action, so a flaky network or an impatient
/// double-tap can never create two pint entries (master prompt §7.8, §16). The database
/// enforces this with a unique constraint on `(user_id, idempotency_key)`.
public struct IdempotencyKey: Sendable, Equatable, Hashable, Codable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func generate() -> IdempotencyKey {
        IdempotencyKey(rawValue: UUID().uuidString)
    }
}
