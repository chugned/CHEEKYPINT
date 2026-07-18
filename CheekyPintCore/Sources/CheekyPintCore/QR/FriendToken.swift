import Foundation
import CryptoKit

/// An opaque, URL-safe friend token. This is the ONLY identifying material placed in a
/// QR code — never an email, UUID, access token, or location (master prompt §8). The
/// server stores just `token_hash`; the raw value lives only on the owner's device and
/// inside the QR image.
public struct FriendToken: Sendable, Equatable, Hashable {
    /// base64url without padding.
    public let rawValue: String

    /// Wrap an existing token, validating that it is well-formed base64url of a sane length.
    public init?(rawValue: String) {
        guard Self.isWellFormed(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    private init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }

    /// Cryptographically-random token. 32 bytes → 256 bits of entropy, so tokens are
    /// unguessable and enumeration-resistant.
    public static func generate(byteCount: Int = 32) -> FriendToken {
        var generator = SystemRandomNumberGenerator() // CSPRNG on Apple platforms
        var bytes = [UInt8]()
        bytes.reserveCapacity(byteCount)
        for _ in 0..<byteCount {
            bytes.append(UInt8.random(in: .min ... .max, using: &generator))
        }
        return FriendToken(unchecked: base64URLEncode(Data(bytes)))
    }

    /// SHA-256 of the raw token as lowercase hex. The Postgres side computes the same
    /// value with `encode(digest(raw, 'sha256'), 'hex')`, so this is only used for tests
    /// and any client-side parity checks — the server hash is authoritative.
    public var sha256Hex: String {
        let digest = SHA256.hash(data: Data(rawValue.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func isWellFormed(_ value: String) -> Bool {
        guard (16...128).contains(value.count) else { return false }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

/// A short, human-typeable friend code for manual entry (master prompt §8). Uses Crockford-
/// style base32 minus visually ambiguous characters (no 0/O, 1/I/L) so it is easy to read
/// aloud and type. This is a *convenience* lookup key, still resolved and rate-limited
/// server-side; it is not a secret on its own.
public struct ShortFriendCode: Sendable, Equatable, Hashable {
    public let rawValue: String

    public static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

    public init?(rawValue: String) {
        let normalised = Self.normalise(rawValue)
        guard normalised.count == 8,
              normalised.allSatisfy({ Self.alphabet.contains($0) }) else { return nil }
        self.rawValue = normalised
    }

    private init(unchecked rawValue: String) { self.rawValue = rawValue }

    public static func generate(length: Int = 8) -> ShortFriendCode {
        var generator = SystemRandomNumberGenerator()
        let chars = (0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] }
        return ShortFriendCode(unchecked: String(chars))
    }

    /// Uppercase and strip spaces/dashes. The alphabet already excludes ambiguous glyphs
    /// (0/O, 1/I/L), so anything outside it is a genuine typo and is rejected by `init?`
    /// rather than silently "corrected" into the wrong friend.
    public static func normalise(_ raw: String) -> String {
        String(raw.uppercased().filter { !$0.isWhitespace && $0 != "-" })
    }

    /// Formatted for display as two groups of four: `ABCD-EF23`.
    public var formatted: String {
        guard rawValue.count == 8 else { return rawValue }
        let mid = rawValue.index(rawValue.startIndex, offsetBy: 4)
        return "\(rawValue[..<mid])-\(rawValue[mid...])"
    }
}

// MARK: - base64url

func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
