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
    /// literally present in `text`. Deleting (or editing away) the visible `@Name` in the
    /// composer is therefore enough to drop that mention — no re-parse of the final text is
    /// needed or attempted. Order of the result is unspecified (it is derived from a
    /// `Dictionary`); callers that care about order must sort or otherwise not depend on it.
    public static func stillPresent(mentions: [UUID: String], in text: String) -> [UUID] {
        mentions.compactMap { id, displayName in
            text.contains("@\(displayName)") ? id : nil
        }
    }
}
