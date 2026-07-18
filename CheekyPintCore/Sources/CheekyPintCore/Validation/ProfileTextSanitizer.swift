import Foundation

/// Cleans user-provided profile text before it is stored or displayed. Strips control
/// and formatting characters (including zero-width and bidi-override tricks), collapses
/// runs of whitespace, and enforces length limits (master prompt §14, §19). This is a
/// belt-and-braces measure — the server sanitises too — but doing it client-side gives
/// immediate feedback and avoids round trips.
public struct ProfileTextSanitizer: Sendable {
    public static let displayNameMaxLength = 40
    public static let bioMaxLength = 160
    public static let cityMaxLength = 60

    public init() {}

    /// Single-line name: no control chars, no line breaks, collapsed spaces, trimmed,
    /// truncated to the display-name limit.
    public func sanitizeDisplayName(_ raw: String) -> String {
        clean(raw, allowNewlines: false, maxLength: Self.displayNameMaxLength)
    }

    /// Single-line broad location, same rules as a name.
    public func sanitizeCity(_ raw: String) -> String {
        clean(raw, allowNewlines: false, maxLength: Self.cityMaxLength)
    }

    /// Multi-line bio: newlines are preserved (collapsed to at most two in a row),
    /// other control chars removed, truncated to the bio limit.
    public func sanitizeBio(_ raw: String) -> String {
        clean(raw, allowNewlines: true, maxLength: Self.bioMaxLength)
    }

    // MARK: - Core

    private func clean(_ raw: String, allowNewlines: Bool, maxLength: Int) -> String {
        // 1. Normalise scalar-by-scalar. Whitespace (tabs, non-breaking spaces) is category
        //    Control/Separator, so it must be mapped to a plain space *before* we drop control
        //    (Cc) and format (Cf — zero-width joiners, bidi overrides) characters; otherwise a
        //    tab would be deleted and glue two words together ("Kings\tArms" → "KingsArms").
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            if scalar == "\r" {
                continue // fold CRLF into a single LF handled below
            } else if scalar == "\n" {
                scalars.append(allowNewlines ? "\n" : " ")
            } else if scalar.properties.generalCategory == .format {
                continue // zero-width joiners/spaces, bidi overrides — drop before the
                         // whitespace check, since some are also reported as whitespace
            } else if CharacterSet.whitespaces.contains(scalar) {
                scalars.append(" ") // tabs and Unicode spaces normalise to a plain space
            } else if scalar.properties.generalCategory == .control {
                continue // other control characters
            } else {
                scalars.append(scalar)
            }
        }
        let filtered = String(scalars)

        // 2. Collapse whitespace. Horizontal runs → single space; blank-line runs → one break.
        let collapsed: String
        if allowNewlines {
            let lines = filtered.split(separator: "\n", omittingEmptySubsequences: false)
                .map { collapseSpaces(String($0)) }
            collapsed = collapseBlankLines(lines).joined(separator: "\n")
        } else {
            collapsed = collapseSpaces(filtered.replacingOccurrences(of: "\n", with: " "))
        }

        // 3. Trim and truncate by grapheme cluster so we never split an emoji or accent.
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxLength { return trimmed }
        return String(trimmed.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func collapseSpaces(_ input: String) -> String {
        input.split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
    }

    /// Never allow more than one consecutive blank line.
    private func collapseBlankLines(_ lines: [String]) -> [String] {
        var result: [String] = []
        var previousBlank = false
        for line in lines {
            let isBlank = line.isEmpty
            if isBlank && previousBlank { continue }
            result.append(line)
            previousBlank = isBlank
        }
        return result
    }
}
