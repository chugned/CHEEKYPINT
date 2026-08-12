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
}
