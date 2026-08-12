import XCTest
@testable import CheekyPintCore

final class UsernameValidatorTests: XCTestCase {
    private let validator = UsernameValidator()

    func testAcceptsAndNormalisesValidUsername() {
        XCTAssertEqual(try validator.validate("  BarnabY_01 ").get(), "barnaby_01")
    }

    func testRejectsTooShortAndTooLong() {
        XCTAssertEqual(validator.validate("ab"), .failure(.tooShort(min: 3)))
        XCTAssertEqual(validator.validate(String(repeating: "a", count: 21)), .failure(.tooLong(max: 20)))
    }

    func testMustStartWithLetter() {
        XCTAssertEqual(validator.validate("1abc"), .failure(.mustStartWithLetter))
        XCTAssertEqual(validator.validate("_abc"), .failure(.mustStartWithLetter))
    }

    func testRejectsInvalidCharacters() {
        XCTAssertEqual(validator.validate("bad-name"), .failure(.invalidCharacters))
        XCTAssertEqual(validator.validate("space name"), .failure(.invalidCharacters))
        XCTAssertEqual(validator.validate("café"), .failure(.invalidCharacters))
    }

    func testRejectsReservedNames() {
        XCTAssertEqual(validator.validate("admin"), .failure(.reserved))
        XCTAssertEqual(validator.validate("CheekyPint"), .failure(.reserved))
    }
}

final class ProfileTextSanitizerTests: XCTestCase {
    private let sanitizer = ProfileTextSanitizer()

    func testStripsControlAndZeroWidthCharacters() {
        // Contains a zero-width space (U+200B) and a bidi override (U+202E).
        let dirty = "Ne\u{200B}d\u{202E}im"
        XCTAssertEqual(sanitizer.sanitizeDisplayName(dirty), "Nedim")
    }

    func testCollapsesWhitespaceAndTrims() {
        XCTAssertEqual(sanitizer.sanitizeDisplayName("  The   Kings\tArms  "), "The Kings Arms")
    }

    func testDisplayNameRemovesNewlines() {
        XCTAssertEqual(sanitizer.sanitizeDisplayName("line1\nline2"), "line1 line2")
    }

    func testBioKeepsNewlinesButCollapsesBlankRuns() {
        let bio = "First line\n\n\n\nSecond line"
        XCTAssertEqual(sanitizer.sanitizeBio(bio), "First line\n\nSecond line")
    }

    func testTruncatesToLimitWithoutSplittingGraphemes() {
        let longName = String(repeating: "🍺", count: 60)
        let result = sanitizer.sanitizeDisplayName(longName)
        XCTAssertEqual(result.count, ProfileTextSanitizer.displayNameMaxLength)
        XCTAssertTrue(result.allSatisfy { $0 == "🍺" }, "must not split the emoji into scalars")
    }

    /// `sanitize(_:allowNewlines:maxLength:)` backs the feed composer's post body (limit 500,
    /// far past `bioMaxLength`), so it must reuse `clean`'s stripping rather than route through
    /// one of the three named, differently-limited methods above.
    func testGenericSanitizeStripsControlCharactersAndKeepsAllowedNewlines() {
        let dirty = "Ne\u{200B}d\u{202E}im\nSecond"
        let result = sanitizer.sanitize(dirty, allowNewlines: true, maxLength: 500)
        XCTAssertEqual(result, "Nedim\nSecond")
    }

    func testGenericSanitizeTruncatesToTheGivenLimitNotABuiltInOne() {
        // 600 in, must come back at exactly 500: feeding exactly the limit would pass whether
        // truncation runs or was deleted entirely, so this must overshoot it.
        let long = String(repeating: "a", count: 600)
        let result = sanitizer.sanitize(long, allowNewlines: false, maxLength: 500)
        XCTAssertEqual(result.count, 500,
                       "must honour the caller's own limit, not silently fall back to " +
                       "bioMaxLength (\(ProfileTextSanitizer.bioMaxLength)) or another built-in")
    }

    // MARK: - Code-point (not grapheme-cluster) length budget
    //
    // Postgres counts code points: `char_length(t)` and `left(t, n)` both do, so every server
    // limit this type mirrors is a code-point limit — `profiles.display_name`'s CHECK constraint
    // (a hard 23514 rejection, since profile writes are a plain PATCH with no clamp),
    // `create_post`'s `left(v_body, 500)`, `add_comment`'s `left(v_body, 280)`. Grapheme-cluster
    // counting (`String.count`/`String.prefix`) diverges from that for any multi-scalar cluster.
    // Each test below names a concrete input that flipped under the old grapheme-based code.

    /// NFD-decomposed umlauts — what macOS puts on the clipboard — are one grapheme cluster and
    /// two code points each (`a` + U+0308 COMBINING DIAERESIS). The combining mark is category Mn,
    /// so step 1 keeps it; only the length budget decides the outcome.
    ///
    /// The flip: 300 NFD characters is 300 grapheme clusters, so grapheme counting saw `300 <= 500`
    /// and returned all 600 code points unchanged — which `left(v_body, 500)` then cut down to 500,
    /// silently dropping 50 characters the client had already told the user were fine.
    func testNFDDecomposedTextIsBudgetedInCodePointsNotGraphemeClusters() {
        let nfd = String(repeating: "a\u{0308}", count: 300)
        XCTAssertEqual(nfd.count, 300, "fixture: 300 user-visible characters")
        XCTAssertEqual(nfd.unicodeScalars.count, 600, "fixture: 600 code points — what Postgres counts")

        let result = sanitizer.sanitize(nfd, allowNewlines: false, maxLength: 500)

        XCTAssertLessThanOrEqual(result.unicodeScalars.count, 500,
                                 "the result must fit left(v_body, 500) with nothing left for the " +
                                 "server to drop; grapheme counting returned all 600 code points")
        XCTAssertEqual(result.unicodeScalars.count, 500, "and must use the whole budget, not undershoot it")
        XCTAssertEqual(result.count, 250, "500 code points of two-scalar clusters is 250 characters")
        XCTAssertTrue(result.unicodeScalars.last == "\u{0308}",
                      "the cut must land on a cluster boundary — an 'a' with its diaeresis " +
                      "stripped off would mean a split cluster")
    }

    /// A flag is two regional-indicator scalars in one cluster, with no combining mark involved —
    /// a second, structurally different multi-scalar shape, to prove the fix isn't specific to
    /// combining marks. 30 flags is 60 code points; a budget of 41 admits 20 whole flags (40
    /// scalars) and must not emit half of the 21st, which would render as a bare letter 'U'.
    func testFlagEmojiAreBudgetedInCodePointsAndNeverSplitMidCluster() {
        let flags = String(repeating: "🇦🇹", count: 30)
        XCTAssertEqual(flags.count, 30)
        XCTAssertEqual(flags.unicodeScalars.count, 60)

        let result = sanitizer.sanitize(flags, allowNewlines: false, maxLength: 41)

        XCTAssertEqual(result.unicodeScalars.count, 40, "an odd budget must round down to whole flags")
        XCTAssertEqual(result.count, 20)
        XCTAssertTrue(result.allSatisfy { $0 == "🇦🇹" }, "must not split a flag into a lone regional indicator")
    }

    /// The profile fields are the harsher failure mode: `profiles.display_name` has a
    /// `char_length(display_name) between 1 and 40` CHECK and profile writes go out as a plain
    /// PostgREST `PATCH` with no server-side clamp, so an over-long value is *rejected* (23514),
    /// not truncated. Under grapheme counting 40 NFD characters passed the client's own limit and
    /// then failed that constraint at 80 code points.
    func testDisplayNameFitsThePostgresCheckConstraintForMultiScalarText() {
        let nfd = String(repeating: "o\u{0308}", count: 40)
        let result = sanitizer.sanitizeDisplayName(nfd)
        XCTAssertLessThanOrEqual(result.unicodeScalars.count, ProfileTextSanitizer.displayNameMaxLength,
                                 "char_length(display_name) <= 40 is a CHECK constraint, not a clamp — " +
                                 "80 code points is a 23514 rejection, not a silent truncation")
        XCTAssertEqual(result.unicodeScalars.count, 40)
        XCTAssertEqual(result.count, 20)
    }

    /// ASCII must be untouched by the change of unit: the same string, the same limit, the same
    /// result as before, because for ASCII scalars and clusters are the same thing.
    func testPureASCIIBehaviourIsUnchangedByTheCodePointBudget() {
        XCTAssertEqual(sanitizer.sanitize(String(repeating: "a", count: 600),
                                          allowNewlines: false, maxLength: 500).count, 500)
        XCTAssertEqual(sanitizer.sanitizeDisplayName("Barnaby Pemberton-Smythe"), "Barnaby Pemberton-Smythe")
        XCTAssertEqual(sanitizer.sanitize("exactly ten", allowNewlines: false, maxLength: 11), "exactly ten")
    }

    // MARK: - sanitizedLength (what a live character counter must display)

    /// The counter's contract: `sanitizedLength` is the code-point length of the *cleaned* text,
    /// so `sanitizedLength <= limit` guarantees `sanitize(…, maxLength: limit)` truncates nothing.
    func testSanitizedLengthIsTheStoredCodePointLengthNotTheRawGraphemeCount() {
        let nfd = String(repeating: "a\u{0308}", count: 300)
        XCTAssertEqual(sanitizer.sanitizedLength(nfd, allowNewlines: false), 600,
                       "a counter showing 300 here would promise the server will keep text it will cut")
    }

    /// ZWJ sequences are the case that makes counting *raw* scalars wrong in the other direction:
    /// step 1 strips the joiners (category Cf), so 80 family emoji reach the server as 320 code
    /// points, not the 560 they occupy in the text field. A counter over-reporting 560 against a
    /// 500 limit would block a post the server would have stored intact.
    func testSanitizedLengthDiscountsStrippedJoinersRatherThanCountingRawScalars() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        let eighty = String(repeating: family, count: 80)
        XCTAssertEqual(eighty.unicodeScalars.count, 560, "fixture: 7 raw scalars per family emoji")

        let length = sanitizer.sanitizedLength(eighty, allowNewlines: true)

        XCTAssertEqual(length, 320, "the joiners are stripped before storage, so they must not be counted")
        XCTAssertEqual(sanitizer.sanitize(eighty, allowNewlines: true, maxLength: 500).unicodeScalars.count, 320,
                       "and a length at or under the limit must mean nothing is truncated")
    }

    /// Collapsed whitespace must be discounted too, for the same reason: the counter has to report
    /// what will be stored, and cleaning collapses runs before storage.
    func testSanitizedLengthDiscountsCollapsedWhitespaceAndTrimming() {
        XCTAssertEqual(sanitizer.sanitizedLength("  a     b  ", allowNewlines: false), 3,
                       "stored as \"a b\" — 3 code points, not the 11 typed")
    }
}
