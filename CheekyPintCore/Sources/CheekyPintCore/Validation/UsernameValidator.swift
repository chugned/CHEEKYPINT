import Foundation

public enum UsernameValidationError: Error, Equatable, Sendable {
    case empty
    case tooShort(min: Int)
    case tooLong(max: Int)
    case invalidCharacters
    case mustStartWithLetter
    case reserved
}

/// Validates and normalises usernames. Usernames are optional (master prompt §10) but,
/// when set, must be predictable and safe: lowercase, URL-friendly, and free of reserved
/// words that could be used for impersonation (e.g. "admin", "support").
public struct UsernameValidator: Sendable {
    public let minLength: Int
    public let maxLength: Int
    public let reserved: Set<String>

    public init(minLength: Int = 3, maxLength: Int = 20, reserved: Set<String> = UsernameValidator.defaultReserved) {
        self.minLength = minLength
        self.maxLength = maxLength
        self.reserved = reserved
    }

    /// Words a normal user may not take, to reduce impersonation and confusion.
    public static let defaultReserved: Set<String> = [
        "admin", "administrator", "root", "support", "help", "cheekypint",
        "official", "moderator", "mod", "staff", "team", "system", "null", "undefined"
    ]

    /// Normalise (trim + lowercase) and validate. On success returns the canonical form
    /// that should be stored, so the caller never persists an unnormalised value.
    public func validate(_ raw: String) -> Result<String, UsernameValidationError> {
        let normalised = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if normalised.isEmpty { return .failure(.empty) }
        if normalised.count < minLength { return .failure(.tooShort(min: minLength)) }
        if normalised.count > maxLength { return .failure(.tooLong(max: maxLength)) }

        guard let first = normalised.first, first.isLetter, first.isASCII else {
            return .failure(.mustStartWithLetter)
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")
        guard normalised.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return .failure(.invalidCharacters)
        }

        if reserved.contains(normalised) { return .failure(.reserved) }

        return .success(normalised)
    }

    public func isValid(_ raw: String) -> Bool {
        if case .success = validate(raw) { return true }
        return false
    }
}
