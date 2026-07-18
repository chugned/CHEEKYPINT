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
}
