import XCTest
import CheekyPintCore
@testable import CheekyPint

/// The last two free-text columns that were raw on **both** sides: `pub_sessions.name` (written by
/// `CreateSessionView`) and `pint_entries.private_note` (written by `LogPintSheet`). Both previously
/// went out untouched and were stored under `left(…, N)` alone — no `strip_ugc_control_chars`, no
/// client sanitising, no bound the user could see.
///
/// `pub_sessions.name` is the one with a cross-user render path: `ActiveSessionView` shows it as the
/// navigation title for every member of the session, so a bidi override in a session name lands on
/// other people's screens. `private_note` is author-only (a single RLS policy, `user_id =
/// auth.uid()`), but it is stored, returned by the RPC and included in the Art. 15 export, so
/// silently trimming it loses data the user can ask for.
///
/// Every gate here is `static` on its view (like `ComposePostSheet.canSubmit`) so the payloads below
/// go through the real predicate, not a copy of it. The server halves are pinned by `t53`/`t54` in
/// `supabase/tests/rls_rpc_suite.sql`.
final class FreeTextWriteSurfaceTests: XCTestCase {

    /// The payload `t53`/`t54` use, in the shapes `ProfileTextSanitizer` exists for.
    private static let trojanPayload = "ab\u{200B}us\u{202E}i\u{2060}ve"

    // MARK: - pub_sessions.name (CreateSessionView)

    /// The bound is the column's own, in code points, and it is a literal: the constant exists only
    /// to mirror `char_length(name) <= 80` and `create_pub_session`'s `left(…, 80)`.
    func testSessionNameLimitMirrorsTheColumn() {
        XCTAssertEqual(CreateSessionView.nameLimit, 80,
                       "must mirror pub_sessions' char_length(name) <= 80 CHECK and left(…, 80)")
    }

    /// Flipped one code point either side of the limit, in both units. 40 NFD characters is 80 code
    /// points and must pass; 41 is 82 and must not — a grapheme-based gate waves both through and
    /// lets the server cut the tail.
    func testSessionNameGateFlipsAtExactlyTheCodePointLimit() {
        XCTAssertTrue(CreateSessionView.nameWithinLimit(""), "a name is optional")
        XCTAssertTrue(CreateSessionView.nameWithinLimit(String(repeating: "z", count: 80)),
                      "exactly 80 must still start a session")
        XCTAssertFalse(CreateSessionView.nameWithinLimit(String(repeating: "z", count: 81)),
                       "81 must block Start session, not lose the 81st character on send")
        XCTAssertTrue(CreateSessionView.nameWithinLimit(String(repeating: "a\u{0308}", count: 40)),
                      "80 code points as 40 NFD characters must be allowed")
        XCTAssertFalse(CreateSessionView.nameWithinLimit(String(repeating: "a\u{0308}", count: 41)),
                       "82 code points must block, even though it is only 41 characters")
    }

    /// The client half of the cross-user fix: nothing in the format category may leave the device, so
    /// the name another member sees as their navigation title cannot carry a bidi override.
    func testSanitizedSessionNameStripsBidiOverridesAndZeroWidthCharacters() throws {
        let clean = try XCTUnwrap(CreateSessionView.sanitizedName(Self.trojanPayload))
        XCTAssertEqual(clean, "abusive",
                       "a zero-width space, an RTL override and a word joiner must all be gone")
        XCTAssertFalse(clean.unicodeScalars.contains { $0.properties.generalCategory == .format },
                       "no format-category scalar may reach another member's screen")
    }

    /// A name that cleans away to nothing must arrive as `nil`, matching the RPC's own
    /// `nullif(…, '')` — an unnamed session falls back to "Session", which beats a blank title.
    func testSessionNamesThatCleanAwayToNothingBecomeNil() {
        XCTAssertNil(CreateSessionView.sanitizedName(""))
        XCTAssertNil(CreateSessionView.sanitizedName("   \t "))
        XCTAssertNil(CreateSessionView.sanitizedName("\u{200B}\u{202E}"),
                     "a name of nothing but invisible characters is not a name")
        XCTAssertEqual(CreateSessionView.sanitizedName("  Friday   at the Kings  "),
                       "Friday at the Kings", "and an ordinary name is trimmed and collapsed, not dropped")
    }

    /// Newlines become spaces rather than vanishing: the column cannot store a line break (the
    /// server's strip deletes `chr(10)`), and deleting it here would run two words together.
    func testASessionNameWithANewlineKeepsItsWordsApart() throws {
        let clean = try XCTUnwrap(CreateSessionView.sanitizedName("Friday\nat the Kings"))
        XCTAssertEqual(clean, "Friday at the Kings")
    }

    // MARK: - pint_entries.private_note (LogPintSheet)

    /// The user's allowance is the column bound minus the longest `[Beer: …]` line and its space.
    /// Flipped one code point either side; the NFD pair proves the unit is code points.
    func testNoteGateFlipsAtExactlyTheDerivedLimit() {
        let limit = LogPintSheet.noteLimit
        XCTAssertTrue(LogPintSheet.noteWithinLimit(""), "a note is optional")
        XCTAssertTrue(LogPintSheet.noteWithinLimit(String(repeating: "z", count: limit)),
                      "a note filling the allowance exactly must still log")
        XCTAssertFalse(LogPintSheet.noteWithinLimit(String(repeating: "z", count: limit + 1)),
                       "one over must disable the beer rows, not lose the last character")

        // `limit` is odd (280 − 1 − 102), so an NFD note of `limit / 2 + 1` characters is `limit + 1`
        // code points: over the line in the server's unit, under it in characters.
        let nfd = String(repeating: "a\u{0308}", count: limit / 2 + 1)
        XCTAssertEqual(nfd.unicodeScalars.count, limit + 1, "fixture: one code point over")
        XCTAssertFalse(LogPintSheet.noteWithinLimit(nfd),
                       "the gate must measure code points, not characters")
    }

    /// The note was previously trimmed only, which leaves every invisible character in place.
    func testSanitizedNoteStripsBidiOverridesAndZeroWidthCharacters() {
        XCTAssertEqual(LogPintSheet.sanitizedNote(Self.trojanPayload), "abusive")
        XCTAssertFalse(
            LogPintSheet.sanitizedNote(Self.trojanPayload).unicodeScalars
                .contains { $0.properties.generalCategory == .format },
            "no format-category scalar may be stored")
    }

    /// The note is sanitised single-line, so a typed newline becomes a space instead of being deleted
    /// server-side and gluing two words into one.
    func testANoteWithNewlinesKeepsItsWordsApart() {
        XCTAssertEqual(LogPintSheet.sanitizedNote("first\nsecond"), "first second")
        XCTAssertEqual(LogPintSheet.sanitizedNote("first\n\n\nsecond"), "first second",
                       "collapsed, not multiplied into a run of spaces")
    }

    /// Whitespace-only notes leave the column NULL via the RPC's `nullif(…, '')`; the client must not
    /// send something that looks like content.
    func testNotesThatCleanAwayToNothingBecomeEmpty() {
        XCTAssertEqual(LogPintSheet.sanitizedNote("   \t\n "), "")
        XCTAssertEqual(LogPintSheet.sanitizedNote("\u{200B}\u{202E}"), "",
                       "a note of nothing but invisible characters stores nothing")
        XCTAssertEqual(LogPintSheet.sanitizedNote("  two   pints  "), "two pints")
    }

    /// The composed value that actually reaches `create_pint_entry`: a sanitised, at-limit note on the
    /// longest beer line in the catalog must still fit the column, with the halves still separated.
    func testTheWorstCaseComposedNoteFitsTheColumn() throws {
        let sanitizer = ProfileTextSanitizer()
        let longest = try XCTUnwrap(
            BeerCatalog.beers.max { BeerCatalog.beerLine(for: $0).count < BeerCatalog.beerLine(for: $1).count })
        let atLimit = String(repeating: "z", count: LogPintSheet.noteLimit)

        let composed = BeerCatalog.diaryNote(for: longest, userNote: LogPintSheet.sanitizedNote(atLimit))

        XCTAssertEqual(sanitizer.sanitizedLength(composed, allowNewlines: false),
                       LogPintSheet.noteColumnLimit,
                       "the worst case must land exactly on 280, not over it")
        XCTAssertTrue(composed.contains("] "), "the beer line and the note must stay separated")
    }
}
