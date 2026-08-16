import Foundation

/// Shared JSON coders configured to match Supabase's snake_case columns and ISO-8601
/// timestamps (with and without fractional seconds). Domain models in CheekyPintCore use
/// camelCase, so `.convertFromSnakeCase` bridges the two without hand-written CodingKeys.
enum SupabaseJSON {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = Self.iso8601.date(from: raw) ?? Self.iso8601NoFraction.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Bad date: \(raw)")
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.iso8601.string(from: date))
        }
        return encoder
    }()

    /// GoTrue (`/auth/v1/...`) gets a **plain** decoder — no `.convertFromSnakeCase`.
    ///
    /// Not a stylistic split. `keyDecodingStrategy` rewrites each incoming key *before* it is
    /// matched against `CodingKeys`, so `.convertFromSnakeCase` turns `access_token` into
    /// `accessToken` and then fails to find it under `GoTrueTokenResponse`'s own
    /// `case accessToken = "access_token"`. Every auth type here spells its wire names out
    /// explicitly, which is only correct against a decoder that leaves keys alone.
    ///
    /// This is not hypothetical: `GoTrueTokenResponse` was decoded with the shared decoder above,
    /// so `verifyEmailOTP`, `signInWithApple` and `refresh` all threw
    /// `keyNotFound("access_token")` on a perfectly good 200. Nothing noticed because nothing in
    /// the app had ever called them — the whole auth surface was unreachable behind the old
    /// surname screen. `EmailOTPAuthTests`' live sign-in is what caught it.
    static let goTrueDecoder = JSONDecoder()

    // ISO8601DateFormatter is documented as thread-safe but isn't Sendable; these are only ever
    // read, so `nonisolated(unsafe)` is correct and avoids re-allocating a formatter per call.
    nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) static let iso8601NoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Parses a Postgres `timestamptz` for display. Reuses the two formatters this enum already
    /// defines for its custom `dateDecodingStrategy` — Postgres trims trailing fractional zeros,
    /// so the sub-second digit count varies per row and one formatter cannot cover both forms.
    /// Display only: the cursor always carries the raw string.
    static func parseTimestamp(_ raw: String) -> Date? {
        iso8601.date(from: raw) ?? iso8601NoFraction.date(from: raw)
    }
}
