import XCTest
@testable import CheekyPintCore

final class MentionScannerTests: XCTestCase {
    func testFindsTheTokenUnderTheCursor() {
        XCTAssertEqual(MentionScanner.activeToken(in: "cheers @bar", upTo: 11), "bar")
        XCTAssertEqual(MentionScanner.activeToken(in: "@ce", upTo: 3), "ce")
        XCTAssertNil(MentionScanner.activeToken(in: "no mention here", upTo: 15))
        XCTAssertNil(MentionScanner.activeToken(in: "email a@b.com", upTo: 13),
                     "an @ with no preceding boundary is not a mention")
    }

    func testTokenEndsAtTheCursorNotTheEndOfText() {
        XCTAssertEqual(MentionScanner.activeToken(in: "@bar and @ceri", upTo: 4), "bar")
    }

    func testKeepsOnlyMentionsStillPresentInTheText() {
        let a = UUID(), b = UUID()
        let mentions = [a: "Barnaby", b: "Ceri"]
        let kept = MentionScanner.stillPresent(mentions: mentions, in: "cheers @Barnaby")
        XCTAssertEqual(kept, [a], "a deleted mention must not be sent to the server")
    }

    func testEmptyWhenNoMentionSurvives() {
        XCTAssertTrue(MentionScanner.stillPresent(mentions: [UUID(): "Barnaby"],
                                                  in: "plain text").isEmpty)
    }

    // MARK: - Additional coverage beyond the brief's Step 1 set

    /// The brief's own note: `stillPresent` is built from a `Dictionary`, whose iteration order is
    /// unspecified, so a test with *more than one* surviving mention must not depend on which
    /// order the dictionary happens to enumerate in. `Set` equality is order-independent; a plain
    /// `XCTAssertEqual(kept, [a, b])` here would be flaky — it would fail on roughly half of all
    /// runs depending on hash seeding, exactly the "test that cannot reliably fail for the right
    /// reason" class this project is watching for.
    func testKeepsMultipleSurvivingMentionsRegardlessOfDictionaryOrder() {
        let a = UUID(), b = UUID()
        let mentions = [a: "Barnaby", b: "Ceri"]
        let kept = MentionScanner.stillPresent(mentions: mentions, in: "cheers @Barnaby and @Ceri too")
        XCTAssertEqual(Set(kept), Set([a, b]))
    }

    /// A mention token must not swallow a newline — pasted multi-paragraph text with a bare "@" at
    /// the end of one line and unrelated text below must not be treated as one long token.
    func testActiveTokenIsNilAcrossANewline() {
        XCTAssertNil(MentionScanner.activeToken(in: "@bar\nbaz", upTo: 8))
    }

    /// The boundary rule keys off the character immediately preceding "@", not merely "a space
    /// exists somewhere earlier" — a hyphen right before "@" must not count as a boundary.
    func testAtSignPrecededByNonWhitespaceNonAtCharacterIsNotAMention() {
        XCTAssertNil(MentionScanner.activeToken(in: "co-@op", upTo: 6))
    }

    // MARK: - Fix round 1: `stillPresent` needs a trailing word boundary, not a bare substring test

    /// The concrete scenario from code review: friends "Ceri" and "Cerian" both recorded (e.g.
    /// the user picked "Ceri" from autocomplete, then backspaced the trailing space and typed
    /// "an"). The final text is `"@Cerian"`, which is a real person's mention, not Ceri's —
    /// `"@Cerian".contains("@Ceri")` is `true`, so a bare substring test wrongly keeps Ceri and
    /// (since Cerian's own token was never recorded via autocomplete here) mentions nobody
    /// correctly. Requiring a word boundary right after the match is what tells "Ceri" apart from
    /// "Cerian" — the character after the match ("a") is a letter, so it must not count.
    func testStillPresentRequiresAWordBoundaryNotJustASubstringMatch() {
        let ceri = UUID()
        XCTAssertTrue(MentionScanner.stillPresent(mentions: [ceri: "Ceri"], in: "@Cerian").isEmpty,
                      "\"@Ceri\" inside \"@Cerian\" is not a real mention of Ceri")
    }

    /// The same id recorded once must not require or produce more than one entry just because its
    /// name appears twice in the text — the result is derived from the (id-keyed) dictionary, so
    /// a duplicate textual occurrence cannot double it, but this pins that down explicitly rather
    /// than relying on that being incidental.
    func testSameFriendMentionedTwiceInTextIsKeptExactlyOnce() {
        let barnaby = UUID()
        let kept = MentionScanner.stillPresent(mentions: [barnaby: "Barnaby"],
                                               in: "@Barnaby said hi, then @Barnaby left")
        XCTAssertEqual(kept, [barnaby])
    }

    /// A mention at the very first character and one ending at the very last character of the
    /// text both need a "boundary" that isn't a following character at all — the boundary check
    /// must treat `text.endIndex` as valid, not crash or reject it. Flips if the end-of-string
    /// case is mishandled (e.g. force-unwrapping the "next character").
    func testMentionsAtTheVeryStartAndVeryEndOfTheTextAreBothKept() {
        let barnaby = UUID(), ceri = UUID()
        let kept = MentionScanner.stillPresent(mentions: [barnaby: "Barnaby", ceri: "Ceri"],
                                               in: "@Barnaby says hi to @Ceri")
        XCTAssertEqual(Set(kept), Set([barnaby, ceri]))
    }

    /// Hyphens and apostrophes inside a display name are ordinary characters to a literal
    /// substring search — this just pins down that punctuation-bearing names keep working once a
    /// trailing boundary check is added (a comma right after the match is a valid boundary; it is
    /// not a letter or digit).
    func testNameContainingHyphenOrApostropheIsMatchedWithATrailingBoundary() {
        let smythe = UUID(), oConnor = UUID()
        let kept = MentionScanner.stillPresent(
            mentions: [smythe: "Pemberton-Smythe", oConnor: "O'Connor"],
            in: "cheers @Pemberton-Smythe, and @O'Connor too")
        XCTAssertEqual(Set(kept), Set([smythe, oConnor]))
    }

    /// A display name that itself contains "@" is an edge case the plain-substring search must
    /// not choke on — the token being searched for is `"@" + displayName`, so a name of `"co@op"`
    /// produces the search token `"@co@op"`, an ordinary (if unusual) literal string.
    func testDisplayNameContainingAnAtSignIsMatchedLiterally() {
        let id = UUID()
        let kept = MentionScanner.stillPresent(mentions: [id: "co@op"], in: "ping @co@op please")
        XCTAssertEqual(kept, [id])
    }
}
