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
