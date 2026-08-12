import Foundation

/// Pure text logic behind the comment composer's `@mention` autocomplete. No SwiftUI or
/// Supabase dependency — sits alongside `ProfileTextSanitizer`, tested with `swift test`.
///
/// Deliberately does **not** re-parse `@names` out of the final comment body on send: display
/// names contain spaces ("Barnaby Pemberton-Smythe"), so a mention token has no unambiguous end
/// once it's back in free text. Instead the caller records `[UUID: displayName]` the moment the
/// user picks a suggestion (`activeToken` finds what to replace), and `stillPresent` checks each
/// recorded name is still literally in the text at send time — which handles deletion (the name
/// is simply gone) without needing to re-derive token boundaries from scratch.
public enum MentionScanner {
    /// The `@token` ending exactly at `cursor`, or `nil` if the text up to the cursor doesn't end
    /// in one. A mention starts at an `@` that is either the first character of `text` or is
    /// immediately preceded by whitespace — this is what stops `a@b.com` (the `@` is preceded by
    /// `a`, not a boundary) from being treated as a mention. `cursor` is a `Character` offset
    /// (matching `String.count`), not a UTF-16 offset. Returns `nil` if the candidate token would
    /// span a newline — a bare `@` left dangling at the end of one line of pasted text is not a
    /// mention that should still be "active" after the caller has moved on to unrelated text below.
    public static func activeToken(in text: String, upTo cursor: Int) -> String? {
        guard cursor >= 0, cursor <= text.count else { return nil }
        let cursorIndex = text.index(text.startIndex, offsetBy: cursor)
        let prefix = text[text.startIndex..<cursorIndex]

        guard let atIndex = prefix.lastIndex(of: "@") else { return nil }
        if atIndex != text.startIndex {
            let beforeIndex = text.index(before: atIndex)
            guard text[beforeIndex].isWhitespace else { return nil }
        }

        let tokenStart = text.index(after: atIndex)
        let token = String(prefix[tokenStart...])
        guard !token.contains(where: \.isNewline) else { return nil }
        return token
    }

    /// Of the recorded `[UUID: displayName]` mentions, the ids whose `@displayName` is still
    /// literally present in `text`, **at a word boundary**. Deleting (or editing away) the
    /// visible `@Name` in the composer is therefore enough to drop that mention — no re-parse of
    /// the final text is needed or attempted. Order of the result is unspecified (it is derived
    /// from a `Dictionary`); callers that care about order must sort or otherwise not depend on it.
    ///
    /// The word-boundary check matters: with friends "Ceri" and "Cerian" both recorded, backing
    /// out of a picked "Ceri" (deleting the trailing space) and typing "an" produces the text
    /// `"@Cerian"`. A bare `text.contains("@Ceri")` is true there — it's a literal substring —
    /// which would wrongly keep mentioning Ceri (a person the final text doesn't actually
    /// reference) while never mentioning Cerian (who was never picked at all). Requiring the
    /// character immediately after the match to not be a letter/digit closes that: `"Ceri"` is
    /// immediately followed by `"a"` in `"Cerian"`, which fails the boundary, so it correctly
    /// does not count as present.
    public static func stillPresent(mentions: [UUID: String], in text: String) -> [UUID] {
        mentions.compactMap { id, displayName in
            hasWordBoundedOccurrence(of: "@\(displayName)", in: text) ? id : nil
        }
    }

    /// Whether `token` occurs in `text` with nothing "continuing" the token immediately after the
    /// match — i.e. the character right after the match, if any, is not a letter or digit. Checks
    /// every occurrence (not just the first), since an early occurrence lacking a boundary
    /// (`"@Ceri"` inside `"@Cerian"`) must not shadow a later, genuinely boundary-valid one.
    private static func hasWordBoundedOccurrence(of token: String, in text: String) -> Bool {
        guard !token.isEmpty else { return false }
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: token, range: searchRange) {
            let boundaryOK = range.upperBound == text.endIndex
                || !(text[range.upperBound].isLetter || text[range.upperBound].isNumber)
            if boundaryOK { return true }
            // Retry from just past this match's start, so an overlapping later occurrence of the
            // same token starting one character on is still found.
            searchRange = text.index(after: range.lowerBound)..<text.endIndex
        }
        return false
    }
}
