import Foundation

/// Cleans user-provided profile text before it is stored or displayed. Strips control
/// and formatting characters (including zero-width and bidi-override tricks), collapses
/// runs of whitespace, and enforces length limits (master prompt §14, §19). This is a
/// belt-and-braces measure — the server sanitises too — but doing it client-side gives
/// immediate feedback and avoids round trips.
///
/// **Every length here is measured in Unicode scalars (code points), because that is what
/// Postgres measures.** `char_length(t)` and `left(t, n)` both count code points, so every
/// server-side limit this type mirrors is a code-point limit:
/// `profiles.display_name`/`bio`/`city` (`char_length` CHECK constraints — a hard `23514`
/// rejection, since profile writes are a plain PostgREST `PATCH` with no server-side clamp),
/// `create_post`'s `left(v_body, 500)`/`left(v_label, 80)`, `add_comment`'s `left(v_body, 280)`,
/// and the report RPCs' `left(p_details, 1000)`.
///
/// Counting grapheme clusters instead (`String.count`, `String.prefix`) diverges from all of
/// those the moment text contains a multi-scalar cluster — NFD-decomposed umlauts (`a` + U+0308,
/// which is what macOS pastes), a flag (two regional indicators), an emoji with a variation
/// selector, a skin-tone modifier. 300 NFD "characters" is 600 code points: one grapheme cluster
/// per user-visible character, two code points each. Under grapheme counting the client would
/// report 300 of 500 used, send all 600 code points, and let `left(v_body, 500)` silently drop
/// the last 50 characters — or, for a display name, be rejected outright by the CHECK constraint.
///
/// Truncation still cuts only at grapheme-cluster boundaries, so the *result* is never a split
/// emoji or an orphaned combining mark; it is the *budget* that is counted in scalars. For pure
/// ASCII the two measures are identical, so nothing about ASCII behaviour changes.
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

    /// General-purpose cleaner for text that doesn't fit the three named profile fields above —
    /// currently the feed composer's post body and place label, whose limits (500 / 80) mirror
    /// server-side clamps (`left(v_body, 500)` / `left(v_label, 80)` in `create_post`) that live
    /// with the caller, not here. Same Trojan Source stripping and whitespace collapsing as
    /// `sanitizeDisplayName`/`sanitizeBio`, just parameterised instead of duplicated per field.
    public func sanitize(_ raw: String, allowNewlines: Bool, maxLength: Int) -> String {
        clean(raw, allowNewlines: allowNewlines, maxLength: maxLength)
    }

    /// How long `raw` will be **once stored** — the cleaned text's code-point count, which is
    /// exactly what Postgres `char_length` will report and what `left(…, n)` measures against.
    ///
    /// This is what a live character counter must display, not `raw.count`. Two independent
    /// reasons: the count must be in the server's unit (see this type's doc), and it must be of
    /// the *cleaned* text, since cleaning both removes scalars (zero-width joiners, bidi
    /// overrides, control characters) and collapses whitespace runs. Counting raw scalars instead
    /// would over-report — 80 ZWJ family emoji are 560 raw scalars but only 320 once the joiners
    /// are stripped — and so would block a post the server would have accepted intact.
    ///
    /// The guarantee this buys the caller: if `sanitizedLength(raw, allowNewlines:) <= limit`,
    /// then `sanitize(raw, allowNewlines:, maxLength: limit)` truncates nothing and the server's
    /// own clamp is a no-op. A counter reading at or under the limit therefore means "all of this
    /// will be stored", not "most of it probably will".
    public func sanitizedLength(_ raw: String, allowNewlines: Bool) -> Int {
        clean(raw, allowNewlines: allowNewlines, maxLength: .max).unicodeScalars.count
    }

    /// Whether `raw` will be stored **whole** in a field bounded to `maxLength` code points — the
    /// gate a caller must pass before saving `sanitize(raw, …, maxLength:)`, because sanitising
    /// *truncates* and truncation is silent.
    ///
    /// The three profile fields' limits are constants on this type (they mirror `profiles`' CHECK
    /// constraints, and profile writes are a plain PostgREST `PATCH` with no server-side clamp), so
    /// their gate belongs here too. The feed composers spell the same comparison out at their own
    /// call sites, because their limits mirror `create_post`/`add_comment` clamps that live with the
    /// caller rather than here — see `sanitize(_:allowNewlines:maxLength:)`.
    ///
    /// Necessary as well as sufficient: `false` does **not** only mean "a tail would be trimmed". A
    /// single grapheme cluster can be arbitrarily many code points, so when the first cluster alone
    /// overflows the budget, `sanitize` correctly yields `""` — saving that would replace what the
    /// user typed with nothing at all. See the truncation loop in `clean`.
    public func fits(_ raw: String, allowNewlines: Bool, maxLength: Int) -> Bool {
        sanitizedLength(raw, allowNewlines: allowNewlines) <= maxLength
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

        // 3. Trim, then truncate to a *code-point* budget while cutting only at grapheme-cluster
        //    boundaries — the budget is the server's unit (see this type's doc), the cut point is
        //    the user's, so the result never exceeds `char_length(…) = maxLength` and never splits
        //    an emoji or strands a combining mark.
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.unicodeScalars.count <= maxLength { return trimmed }
        var truncated = ""
        var scalarsUsed = 0
        for character in trimmed {
            let width = character.unicodeScalars.count
            // A cluster that doesn't fit ends the loop rather than being partially emitted. The
            // degenerate case — a single cluster wider than the whole budget — therefore yields
            // "", which is correct rather than convenient: emitting a partial cluster would break
            // the code-point guarantee this function exists to provide.
            //
            // That case IS reachable, on any limit. Nonspacing marks (category Mn) are neither
            // control nor format nor whitespace, so step 1 keeps every one of them, and a grapheme
            // cluster can hold unboundedly many: "a" followed by U+0300…U+0332 four times over is
            // one cluster of 205 scalars, so `sanitizeBio` (limit 160) returns "" and
            // `sanitizeDisplayName` (limit 40) needs only 41.
            //
            // Which is why truncating is never a caller's *last* line of defence for text a user
            // typed. Callers that write user input must gate on
            // `sanitizedLength(_:allowNewlines:) <= limit` first and tell the user when it fails —
            // the two composers, both report screens and both profile screens all do — so this
            // branch only ever runs behind a check the user has already been shown. Saving the
            // result of an ungated call would turn "your text is too long" into an empty column.
            guard scalarsUsed + width <= maxLength else { break }
            truncated.append(character)
            scalarsUsed += width
        }
        return truncated.trimmingCharacters(in: .whitespacesAndNewlines)
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
