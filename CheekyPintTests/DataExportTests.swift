import XCTest
@testable import CheekyPint

/// DSGVO Art. 15 (access) / Art. 20 (portability) self-service export. `FeedRepository
/// .exportMyData()` returns the server's raw, unparsed bytes; `DataExportView` must hand those
/// exact bytes to the user (never a decoded/re-encoded copy — that would reorder keys and
/// reformat numbers, so the file would no longer be what the server attested to) and must
/// surface the `truncated` flag, because a silently partial export does not satisfy Art. 15 —
/// the person cannot know what is missing.
///
/// Every assertion here exercises a pure static helper on `DataExportView` directly (the same
/// pattern `ComposePostSheet.canPost` / `.storagePath` use elsewhere in this suite), not the
/// rendered view — this codebase has no view-inspection tooling, and these are the exact
/// functions the view's body calls to decide what bytes to write and what to show.
final class DataExportTests: XCTestCase {

    // MARK: Byte-for-byte (no decode/re-encode)

    /// The fixture is deliberately NOT canonical JSON: extra inter-token whitespace and a
    /// trailing newline that any decode→re-encode round trip normalises away. A test that only
    /// checked "the written file is non-empty" would pass even if the implementation decoded
    /// and re-encoded the document — this fixture is chosen specifically so that bug changes
    /// the bytes.
    func testWrittenFileIsByteForByteTheServersBytesNotAReencode() throws {
        let raw = Data("{\"exported_at\":  \"2026-08-12T00:00:00Z\",   \"truncated\":false}\n".utf8)

        // Prove the fixture is actually a trap: a naive JSONSerialization round trip changes it.
        // If this assertion ever fails, the fixture below stopped being a valid flip input.
        let reencoded = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: raw))
        XCTAssertNotEqual(reencoded, raw, "fixture bug: this input must not already be canonical JSON")

        let filename = "test-byte-for-byte-\(UUID().uuidString).json"
        let url = try DataExportView.write(raw, filename: filename)
        defer { try? FileManager.default.removeItem(at: url) }
        let written = try Data(contentsOf: url)

        XCTAssertEqual(written, raw, "the exported file must be byte-for-byte identical to the server's bytes")
        XCTAssertNotEqual(written, reencoded,
                           "a decode/re-encode implementation would still pass a weaker 'non-empty' check " +
                           "but must fail this exact-bytes comparison")
    }

    // MARK: truncated flag → user-visible warning

    func testTruncatedTrueProducesAUserVisibleWarning() {
        let data = Data(#"{"exported_at":"2026-08-12T00:00:00Z","truncated":true}"#.utf8)
        XCTAssertTrue(DataExportView.isTruncated(data))
        XCTAssertNotNil(
            DataExportView.warningMessage(forTruncated: DataExportView.isTruncated(data)),
            "a truncated:true export must show the user a warning — Art. 15 access is not " +
            "satisfied by a silently partial file the person has no way to know is incomplete")
    }

    func testTruncatedFalseProducesNoWarning() {
        let data = Data(#"{"exported_at":"2026-08-12T00:00:00Z","truncated":false}"#.utf8)
        XCTAssertFalse(DataExportView.isTruncated(data))
        XCTAssertNil(
            DataExportView.warningMessage(forTruncated: DataExportView.isTruncated(data)),
            "a complete (truncated:false) export must not show the truncation warning")
    }

    /// Demo mode's stub is `{"demo":true}` — no `truncated` key at all. This must read as
    /// "not truncated" rather than crash or (worse) mislead by defaulting to `true`.
    func testMissingTruncatedKeyOnTheDemoStubIsTreatedAsNotTruncated() {
        let demoStub = Data(#"{"demo":true}"#.utf8)
        XCTAssertFalse(DataExportView.isTruncated(demoStub), "a missing key must not crash or default to truncated")
        XCTAssertNil(DataExportView.warningMessage(forTruncated: DataExportView.isTruncated(demoStub)))
    }

    // MARK: Filename — stable and dated

    func testFilenameIsStableAndDated() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 12; components.hour = 23; components.minute = 30
        let date = calendar.date(from: components)!

        XCTAssertEqual(DataExportView.filename(date: date), "cheekypint-export-2026-08-12.json")
        // Stable: the same instant must always produce the identical string.
        XCTAssertEqual(DataExportView.filename(date: date), DataExportView.filename(date: date))

        // Dated: a different calendar day is the concrete input that must flip the filename —
        // this is what a hardcoded/constant filename implementation would fail.
        let nextDay = calendar.date(byAdding: .day, value: 1, to: date)!
        XCTAssertEqual(DataExportView.filename(date: nextDay), "cheekypint-export-2026-08-13.json")
        XCTAssertNotEqual(DataExportView.filename(date: date), DataExportView.filename(date: nextDay))
    }

    // MARK: Rate-limit rejection reads as actionable, not generic

    /// The RPC's own rate-limit hint text ("Please slow down and try again shortly.",
    /// `enforce_rate_limit`, 20260101000600_security_helpers.sql) is generic and does not tell
    /// the user this specific action is capped at 5/24h or that tomorrow it will work again.
    /// This is the concrete input (a `.rateLimited` error) that must flip away from that generic
    /// server hint to export-specific, actionable copy.
    func testRateLimitedErrorReadsAsActionableNotTheGenericServerHint() {
        let message = DataExportView.errorMessage(for: SupabaseError.rateLimited(hint: "Please slow down and try again shortly."))
        XCTAssertTrue(message.localizedCaseInsensitiveContains("tomorrow"),
                      "a rate-limited export must tell the user when they can try again; got: \(message)")
        XCTAssertNotEqual(message, "Please slow down and try again shortly.",
                          "must not fall back to the generic server hint for this specific, well-known limit")
    }

    func testOtherSupabaseErrorsStillUseTheStandardFriendlyMessage() {
        let message = DataExportView.errorMessage(for: SupabaseError.offline)
        XCTAssertEqual(message, SupabaseError.offline.friendlyMessage,
                       "non-rate-limit errors must not be swallowed by the rate-limit special case")
    }
}
