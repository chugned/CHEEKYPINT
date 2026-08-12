import XCTest
@testable import CheekyPint

/// DSGVO Art. 15 (access) / Art. 20 (portability) self-service export. `FeedRepository
/// .exportMyData()` returns the server's raw, unparsed bytes; `DataExportView` must hand those
/// exact bytes to the user (never a decoded/re-encoded copy — that would reorder keys and
/// reformat numbers, so the file would no longer be what the server attested to), must surface
/// the `truncated` flag honestly (including when it can't be determined at all — an unverifiable
/// export must never be presented as a verified-complete one), and must not let a full
/// personal-data export sit indefinitely in `tmp`.
///
/// Every assertion here exercises a pure static helper on `DataExportView` directly (the same
/// pattern `ComposePostSheet.canPost` / `.storagePath` use elsewhere in this suite), not the
/// rendered view — this codebase has no view-inspection tooling, and these are the exact
/// functions the view's body calls to decide what bytes to write and what to show.
final class DataExportTests: XCTestCase {

    override func tearDown() {
        DataExportView.clearExportDirectory()
        super.tearDown()
    }

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

        let url = try DataExportView.write(raw, filename: "cheekypint-export-2026-08-12.json")
        let written = try Data(contentsOf: url)

        XCTAssertEqual(written, raw, "the exported file must be byte-for-byte identical to the server's bytes")
        XCTAssertNotEqual(written, reencoded,
                           "a decode/re-encode implementation would still pass a weaker 'non-empty' check " +
                           "but must fail this exact-bytes comparison")
    }

    // MARK: truncated flag → three distinguishable outcomes (complete / truncated / unverifiable)

    func testTruncatedTrueProducesAUserVisibleWarning() {
        let data = Data(#"{"exported_at":"2026-08-12T00:00:00Z","truncated":true}"#.utf8)
        XCTAssertEqual(DataExportView.truncationStatus(of: data), .truncated)
        XCTAssertNotNil(
            DataExportView.warningMessage(for: DataExportView.truncationStatus(of: data)),
            "a truncated:true export must show the user a warning — Art. 15 access is not " +
            "satisfied by a silently partial file the person has no way to know is incomplete")
    }

    func testTruncatedFalseProducesNoWarning() {
        let data = Data(#"{"exported_at":"2026-08-12T00:00:00Z","truncated":false}"#.utf8)
        XCTAssertEqual(DataExportView.truncationStatus(of: data), .complete)
        XCTAssertNil(
            DataExportView.warningMessage(for: DataExportView.truncationStatus(of: data)),
            "a complete (truncated:false) export must not show any warning")
    }

    /// Demo mode's stub is `{"demo":true}` — no `truncated` key at all. This must read as
    /// "complete" rather than crash or (worse) mislead by defaulting to truncated/unverifiable.
    func testMissingTruncatedKeyOnTheDemoStubIsTreatedAsComplete() {
        let demoStub = Data(#"{"demo":true}"#.utf8)
        XCTAssertEqual(DataExportView.truncationStatus(of: demoStub), .complete,
                       "the legitimate demo-stub shape must not be treated as truncated or unverifiable")
        XCTAssertNil(DataExportView.warningMessage(for: DataExportView.truncationStatus(of: demoStub)))
    }

    // MARK: Anomalous / unparseable shapes must never silently read as "complete"
    //
    // The previous implementation wrapped the whole decode in `try?` and collapsed every one of
    // these into `false` ("not truncated") — a partial export with no warning, exactly the Art.
    // 15 failure the flag exists to prevent. Each of the four inputs below is a distinct,
    // concrete way that used to happen; each must now land on `.unverifiable`, never `.complete`.

    func testTruncatedAsAStringIsUnverifiableNotCoerced() {
        let data = Data(#"{"truncated":"true"}"#.utf8)
        XCTAssertEqual(DataExportView.truncationStatus(of: data), .unverifiable,
                       "a string value for truncated is anomalous for a documented boolean field — " +
                       "this code must not guess whether \"true\" means true")
    }

    func testTruncatedAsANumberIsUnverifiableNotCoerced() {
        let data = Data(#"{"truncated":1}"#.utf8)
        XCTAssertEqual(DataExportView.truncationStatus(of: data), .unverifiable,
                       "a numeric value for truncated is anomalous for a documented boolean field — " +
                       "this code must not guess whether 1 means true")
    }

    func testTopLevelJSONArrayIsUnverifiable() {
        let data = Data("[1,2,3]".utf8)
        XCTAssertEqual(DataExportView.truncationStatus(of: data), .unverifiable,
                       "a non-object top-level document cannot be read for a truncated flag at all")
    }

    func testMalformedBytesAreUnverifiable() {
        let data = Data(#"{"truncated": tru"#.utf8) // deliberately cut off mid-token — invalid JSON
        XCTAssertEqual(DataExportView.truncationStatus(of: data), .unverifiable,
                       "malformed/partial bytes must never be silently read as a complete export")
    }

    /// The `.unverifiable` warning must exist (an unverifiable export must not be presented as
    /// verified-complete) but must read as calm and honest, not alarming, and must not be the
    /// same copy as the `.truncated` warning — they mean different things.
    func testUnverifiableWarningIsPresentCalmAndDistinctFromTheTruncatedWarning() throws {
        let unverifiable = try XCTUnwrap(DataExportView.warningMessage(for: .unverifiable),
                                         "an unverifiable export must still warn — Art. 15 forbids " +
                                         "presenting it as verified-complete")
        let truncated = try XCTUnwrap(DataExportView.warningMessage(for: .truncated))
        XCTAssertNotEqual(unverifiable, truncated, "the two warnings mean different things and must not share copy")
        XCTAssertFalse(unverifiable.localizedCaseInsensitiveContains("corrupt"),
                       "copy must stay calm/honest ('couldn't confirm this is complete'), not alarming " +
                       "('your data is corrupted')")
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

    // MARK: Bounded on-disk lifetime — a full personal-data export must not accumulate in `tmp`

    /// The concrete bug this fixes: export today, export again tomorrow (a different filename,
    /// since the name is dated) — the previous implementation wrote loose into `tmp` by filename
    /// alone, so both complete dumps of the person's data persisted side by side. A new export
    /// must sweep any file left from a previous run, not add to it.
    func testWriteSweepsAnyStaleFileFromAPreviousExportBeforeWritingTheNewOne() throws {
        let stale = try DataExportView.write(Data("stale-export".utf8), filename: "cheekypint-export-2026-08-11.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path), "sanity: the stale file must exist first")

        let fresh = try DataExportView.write(Data("fresh-export".utf8), filename: "cheekypint-export-2026-08-12.json")

        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path),
                       "preparing a new export must sweep a stale file from a previous run/day, not " +
                       "leave a second full personal-data dump sitting alongside it")
    }

    /// Models the "the view goes away" half of the fix — `DataExportView.onDisappear` calls
    /// exactly this function.
    func testClearExportDirectoryRemovesTheWrittenFile() throws {
        let url = try DataExportView.write(Data("export-body".utf8), filename: "cheekypint-export-2026-08-12.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "sanity: the file must exist before removal")

        DataExportView.clearExportDirectory()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "leaving the export screen must not leave a full personal-data export sitting in tmp")
    }

    /// Replaces `testClearExportDirectoryIsSafeToCallWhenNothingExists`, which created no file and
    /// therefore passed verbatim against `static func clearExportDirectory() {}` — it proved only
    /// "doesn't crash", which `try?`'s signature already guarantees.
    ///
    /// Real idempotency needs something to remove first: write a file, clear repeatedly, and
    /// require both the file and the directory to be gone and a subsequent export to still work.
    /// The nothing-to-clear path this covers is load-bearing now that `SessionController.bootstrap`
    /// calls `clearExportDirectory()` on every launch — on a clean install, and on every launch
    /// after the first, that call finds nothing, and it must neither fail nor leave the directory
    /// in a state the next export can't be written into.
    func testClearExportDirectoryIsIdempotentAcrossRepeatedCalls() throws {
        let url = try DataExportView.write(Data("export-body".utf8), filename: "cheekypint-export-2026-08-12.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "sanity: something must exist to remove")

        DataExportView.clearExportDirectory()
        DataExportView.clearExportDirectory() // the nothing-to-clear path a normal launch hits
        DataExportView.clearExportDirectory()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "the first call must actually remove the file — a no-op implementation " +
                       "passes a test that never wrote one")
        XCTAssertFalse(FileManager.default.fileExists(atPath: DataExportView.exportDirectory.path),
                       "the directory itself must be gone, not just emptied")

        // Repeated clears must not leave the directory unusable: the launch sweep runs before any
        // export, so a sweep that broke the next `write` would break the feature outright.
        let again = try DataExportView.write(Data("second-export".utf8), filename: "cheekypint-export-2026-08-13.json")
        XCTAssertEqual(try Data(contentsOf: again), Data("second-export".utf8),
                       "an export must still be writable after repeated sweeps")
    }

    // MARK: Launch-time sweep — the one gap `.onDisappear` cannot cover
    //
    // `DataExportView` sweeps before each export and again on `.onDisappear`, but a process that
    // dies while that screen is open fires no `.onDisappear`: a force-quit or an OOM kill leaves a
    // complete personal-data dump in `tmp` with no remaining code path that will ever remove it,
    // since iOS's `tmp` reclamation is opportunistic rather than scheduled. DSGVO Art. 5(1)(e)
    // storage limitation makes an unbounded window there indefensible.

    /// Models exactly that: a file left behind by a previous run, then a launch.
    /// `SessionController.bootstrap()` is the app's launch-time work (`CheekyPintApp`'s root
    /// `.task` calls it), and the sweep is the first thing it does — before every early return, so
    /// it happens whichever phase the launch resolves to.
    ///
    /// The flip point: delete the `sweepStaleTemporaryExports()` call from `bootstrap()` and the
    /// leftover file is still there afterwards.
    @MainActor
    func testLaunchBootstrapSweepsAnExportLeftBehindByAForceQuit() async throws {
        let leftover = try DataExportView.write(
            Data(#"{"profile":{},"pints":[],"posts":[]}"#.utf8),
            filename: "cheekypint-export-2026-08-11.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: leftover.path),
                      "sanity: the previous run's export must exist before the launch")

        let config = AppConfig(environment: .development,
                               supabaseURL: URL(string: "https://unreachable.invalid")!,
                               supabaseAnonKey: "k", universalHost: "unreachable.invalid")
        let session = SessionController(container: AppContainer(config: config))

        await session.bootstrap()

        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path),
                       "launching must sweep a personal-data export orphaned by a force-quit — " +
                       "nothing else ever will: .onDisappear never fired and iOS tmp reclamation " +
                       "is opportunistic")
        XCTAssertFalse(FileManager.default.fileExists(atPath: DataExportView.exportDirectory.path))
    }
}
