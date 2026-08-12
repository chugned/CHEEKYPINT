import XCTest
import SwiftUI
@testable import CheekyPint

/// `PostCommentsSheet`'s pure, testable helpers — `applyingMentionSelection` (the core of picking
/// an autocomplete suggestion) and the two `highlightedBody` overloads (rendering mentions).
/// Follows the same "extract a static pure func off a View struct and test it directly" pattern
/// as `ComposePostSheet.canPost`/`PlacePickerSheet.clampedLabel`.
final class PostCommentsSheetTests: XCTestCase {

    private func friend(_ id: UUID, _ name: String) -> FriendDTO {
        FriendDTO(userId: id, displayName: name, avatarPath: nil, city: nil, friendSince: nil)
    }

    // MARK: - canSend / bodyLength (the composer's limit gate)

    /// The concrete defect this closes: there was no counter and no limit check, so a 350-character
    /// comment left Send enabled, `PostCommentsViewModel.send` clamped it to 280, reported success,
    /// and the composer cleared the draft — 70 characters destroyed with nothing on screen to say
    /// so. `ComposePostSheet.canSubmit` has always refused to do that for its own 500 limit.
    ///
    /// 280 is pinned as a literal on purpose: `PostCommentsViewModel.bodyLimit` exists solely to
    /// mirror `add_comment`'s `left(v_body, 280)`, so deriving the expectation from the constant
    /// would keep this green if someone changed the constant to 99 and desynchronised it from the
    /// server.
    func testCommentOverTheLimitBlocksSend() {
        XCTAssertEqual(PostCommentsSheet.bodyLimit, 280,
                       "must mirror add_comment's left(v_body, 280) — asserted as a literal so a " +
                       "change to the constant fails here instead of silently redefining the limit")

        let atLimit = String(repeating: "a", count: 280)
        XCTAssertTrue(PostCommentsSheet.canSend(body: atLimit), "exactly 280 must still be sendable")
        XCTAssertFalse(PostCommentsSheet.canSend(body: atLimit + "b"),
                       "281 characters must block Send, not silently lose the 281st on send")
        XCTAssertFalse(PostCommentsSheet.canSend(body: String(repeating: "a", count: 350)),
                       "the reported case: 350 characters must block Send rather than being cut to 280")
    }

    func testEmptyOrWhitespaceOnlyCommentBlocksSend() {
        XCTAssertFalse(PostCommentsSheet.canSend(body: ""))
        XCTAssertFalse(PostCommentsSheet.canSend(body: "   \n\t "),
                       "whitespace-only is what the server's btrim calls empty")
        XCTAssertTrue(PostCommentsSheet.canSend(body: "Cheers"))
    }

    /// The counter and the gate must both measure code points — what `left(v_body, 280)` counts —
    /// not grapheme clusters. 200 NFD umlauts is 200 user-visible characters and 400 code points:
    /// grapheme counting would show "200/280" with Send enabled and then hand the server 400 code
    /// points to cut down to 280.
    func testCounterAndGateMeasureCodePointsSoNFDTextCannotOverrunTheServerLimit() {
        let nfd = String(repeating: "a\u{0308}", count: 200)
        XCTAssertEqual(nfd.count, 200, "fixture: 200 user-visible characters")

        XCTAssertEqual(PostCommentsSheet.bodyLength(of: nfd), 400,
                       "the counter must show the stored code-point length, not the 200 typed")
        XCTAssertFalse(PostCommentsSheet.canSend(body: nfd),
                       "400 code points exceeds 280, so Send must be blocked rather than letting " +
                       "the server drop 120 of them")
    }

    // MARK: - applyingMentionSelection

    func testSelectingFromScratchInsertsTheNameAndRecordsTheMention() {
        let barnaby = UUID()
        let result = PostCommentsSheet.applyingMentionSelection(
            friend(barnaby, "Barnaby"), to: "hello @b", mentions: [:])
        XCTAssertEqual(result.text, "hello @Barnaby ")
        XCTAssertEqual(result.mentions, [barnaby: "Barnaby"])
    }

    /// Code review's second concrete scenario: pick "Ceri" (text becomes `"@Ceri "`, recording
    /// `ceriID`), then — because `"Ceri "` still substring-matches a friend "Ceri Ann" — pick that
    /// suggestion too. Without pruning, `mentions` keeps both ids and the final text
    /// `"@Ceri Ann "` genuinely contains `"@Ceri"` at a valid word boundary, so both would survive
    /// `stillPresent` and a second person would be mentioned by accident. The concrete flip point:
    /// remove the pruning step and `result.mentions` becomes `[ceriID: "Ceri", ceriAnnID: "Ceri
    /// Ann"]` instead of just the latter.
    func testSelectingASuggestionThatExtendsAnAlreadyPickedOnePrunesTheStaleMention() {
        let ceri = UUID(), ceriAnn = UUID()
        let afterFirstPick = "@Ceri "
        let startingMentions = [ceri: "Ceri"]

        let result = PostCommentsSheet.applyingMentionSelection(
            friend(ceriAnn, "Ceri Ann"), to: afterFirstPick, mentions: startingMentions)

        XCTAssertEqual(result.text, "@Ceri Ann ")
        XCTAssertEqual(result.mentions, [ceriAnn: "Ceri Ann"],
                       "the stale Ceri id must be pruned, leaving only the final pick")
    }

    /// Pruning must be scoped to the token region being overwritten — an earlier, unrelated
    /// mention elsewhere in the draft must survive untouched. Flips if pruning is done against
    /// the whole draft instead of "the draft with the active token region removed": Barnaby's
    /// mention text isn't inside the region being replaced, so a correct implementation keeps it.
    func testSelectingASuggestionDoesNotPruneAnUnrelatedEarlierMention() {
        let barnaby = UUID(), ceri = UUID()
        let result = PostCommentsSheet.applyingMentionSelection(
            friend(ceri, "Ceri"), to: "@Barnaby said hi to @Cer", mentions: [barnaby: "Barnaby"])

        XCTAssertEqual(result.text, "@Barnaby said hi to @Ceri ")
        XCTAssertEqual(result.mentions, [barnaby: "Barnaby", ceri: "Ceri"],
                       "Barnaby's earlier, unrelated mention must not be pruned")
    }

    func testSelectingWithNoActiveAtSignReturnsTextAndMentionsUnchanged() {
        let barnaby = UUID()
        let result = PostCommentsSheet.applyingMentionSelection(
            friend(barnaby, "Barnaby"), to: "no at sign here", mentions: [:])
        XCTAssertEqual(result.text, "no at sign here")
        XCTAssertTrue(result.mentions.isEmpty)
    }

    // MARK: - highlightedBody

    func testHighlightedBodyOnlyColoursNamesResolvedFromMentionedUserIDs() {
        let ceri = UUID(), barnaby = UUID()
        let friends = [friend(ceri, "Ceri"), friend(barnaby, "Barnaby")]

        // The body literally contains "@Ceri" too, but only Barnaby is in `mentionedUserIds` —
        // e.g. the author typed "@Ceri" by hand without ever using autocomplete, so the server
        // never recorded a mention of Ceri (`add_comment` only records ids passed in
        // `p_mentions`). The rendered text must not colour "@Ceri" as if it were a real mention.
        let attributed = PostCommentsSheet.highlightedBody(
            "cheers @Barnaby and also @Ceri", mentionedUserIDs: [barnaby], friends: friends)

        let plain = String(attributed.characters)
        XCTAssertEqual(plain, "cheers @Barnaby and also @Ceri", "the visible text must be unchanged")

        var coloursByRun: [(String, Bool)] = []
        for run in attributed.runs {
            let text = String(attributed[run.range].characters)
            coloursByRun.append((text, run.foregroundColor == Theme.Palette.forest))
        }
        let highlightedSubstrings = coloursByRun.filter(\.1).map(\.0)
        XCTAssertEqual(highlightedSubstrings, ["@Barnaby"],
                       "only the confirmed mention (Barnaby) may be highlighted — not the " +
                       "literal, unconfirmed \"@Ceri\" text")
    }

    func testHighlightedBodyHighlightsNothingWhenThereAreNoMentionedUserIDs() {
        let attributed = PostCommentsSheet.highlightedBody(
            "cheers @Barnaby", mentionedUserIDs: [], friends: [friend(UUID(), "Barnaby")])
        XCTAssertFalse(attributed.runs.contains { $0.foregroundColor == Theme.Palette.forest })
    }

    /// A mentioned id outside the viewer's own friends list can't be resolved to a name (no RPC
    /// exists for that), so it simply isn't highlighted — a documented cosmetic gap. This pins
    /// down that the function degrades gracefully (no crash, plain text preserved) rather than
    /// asserting it can somehow highlight a name it has no way to know.
    func testHighlightedBodyIgnoresAMentionedIDNotInTheFriendsList() {
        let unknown = UUID()
        let attributed = PostCommentsSheet.highlightedBody(
            "cheers @Someone", mentionedUserIDs: [unknown], friends: [])
        XCTAssertEqual(String(attributed.characters), "cheers @Someone")
        XCTAssertFalse(attributed.runs.contains { $0.foregroundColor == Theme.Palette.forest })
    }
}
