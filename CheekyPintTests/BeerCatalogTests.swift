import XCTest
import CheekyPintCore
@testable import CheekyPint

/// The catalog no longer carries imagery. These pin the shape that survived so the 98 entries
/// and the diary-note behaviour cannot regress while the image layer is removed.
final class BeerCatalogTests: XCTestCase {

    func testCatalogStillHasEveryBeer() {
        XCTAssertEqual(BeerCatalog.beers.count, 98)
    }

    func testEveryBeerHasDisplayableText() {
        for beer in BeerCatalog.beers {
            XCTAssertFalse(beer.name.isEmpty, "\(beer.id) has no name")
            XCTAssertFalse(beer.country.isEmpty, "\(beer.id) has no country")
            XCTAssertFalse(beer.style.isEmpty, "\(beer.id) has no style")
        }
    }

    func testBeerIDsAreUnique() {
        XCTAssertEqual(Set(BeerCatalog.beers.map(\.id)).count, BeerCatalog.beers.count)
    }

    func testDiaryNoteIncludesTheBeerName() {
        let beer = BeerCatalog.beers[0]
        let note = BeerCatalog.diaryNote(for: beer, userNote: "")
        XCTAssertTrue(note.contains(beer.name), "expected \(beer.name) in \(note)")
    }

    // MARK: - The composed note must survive `create_pint_entry`'s sanitiser

    /// The app-authored beer line and the user's own words are separate paragraphs. This asserted the
    /// opposite one commit ago: the space-join existed only because `create_pint_entry` ran the
    /// single-line `strip_ugc_control_chars`, which deletes `chr(10)`, so a newline separator was
    /// removed server-side and glued the glass note onto the user's first word.
    /// `strip_ugc_control_chars_multiline` keeps it (pinned by `t54`).
    func testDiaryNoteJoinsTheTwoHalvesWithANewline() {
        let beer = BeerCatalog.beers[0]
        let note = BeerCatalog.diaryNote(for: beer, userNote: "My round, apparently")

        XCTAssertEqual(note, BeerCatalog.beerLine(for: beer) + "\nMy round, apparently",
                       "the beer line, one break, then the user's words — nothing else")
        XCTAssertEqual(note.filter { $0 == "\n" }.count, 1,
                       "exactly one separator, so the newline's single code point is all noteLimit reserves")
        XCTAssertEqual(BeerCatalog.beerName(in: note), beer.name,
                       "the round trip HomeViewModel relies on must still work")
    }

    /// No user note means no separator at all — not a trailing space.
    func testDiaryNoteWithoutAUserNoteIsExactlyTheBeerLine() {
        let beer = BeerCatalog.beers[0]
        XCTAssertEqual(BeerCatalog.diaryNote(for: beer, userNote: ""), BeerCatalog.beerLine(for: beer))
    }

    /// `LogPintSheet` sanitises the *user's* half and then composes, so the app-authored half has to
    /// be clean already. Flipped by a single tab or zero-width character in any name or glass note.
    func testNoBeerLineContainsAnythingTheSanitiserWouldStrip() {
        let sanitizer = ProfileTextSanitizer()
        for beer in BeerCatalog.beers {
            let line = BeerCatalog.beerLine(for: beer)
            XCTAssertEqual(sanitizer.sanitize(line, allowNewlines: false, maxLength: 280), line,
                           "\(beer.id)'s beer line is altered by sanitising: \(line)")
        }
    }

    /// The guarantee `LogPintSheet.noteLimit` exists to provide: for **every** beer in the catalog, a
    /// note filling the whole allowance still fits `private_note`'s 280 code points, so
    /// `left(…, 280)` never has anything to cut. Flipped by raising `noteLimit` by one — the longest
    /// beer line then overflows.
    func testAFullLengthNoteFitsTheColumnForEveryBeerInTheCatalog() {
        let sanitizer = ProfileTextSanitizer()
        let fullNote = String(repeating: "z", count: LogPintSheet.noteLimit)

        XCTAssertEqual(LogPintSheet.noteColumnLimit, 280,
                       "must mirror pint_entries' char_length(private_note) <= 280 CHECK")

        for beer in BeerCatalog.beers {
            let composed = BeerCatalog.diaryNote(for: beer, userNote: fullNote)
            XCTAssertLessThanOrEqual(
                sanitizer.sanitizedLength(composed, allowNewlines: false), LogPintSheet.noteColumnLimit,
                "\(beer.id): a full-length note overflows the column, so the server would trim it")
        }
    }

    /// The derived limit must not be quietly eaten by a long catalog entry. Adding a beer with a
    /// 200-character glass note would shrink the user's note field to 79 characters with nothing
    /// failing; this makes that loud instead.
    func testTheDerivedNoteLimitStaysAReasonableSizeForTheUser() {
        XCTAssertGreaterThanOrEqual(
            LogPintSheet.noteLimit, 150,
            "a catalog entry long enough to push the note allowance below 150 is the bug, not the limit")
        XCTAssertLessThan(LogPintSheet.noteLimit, LogPintSheet.noteColumnLimit,
                          "the beer line always takes some of the 280")
    }
}
