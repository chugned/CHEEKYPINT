import SwiftUI

/// DSGVO Art. 15 (access) / Art. 20 (portability) self-service export. Structured like
/// `DeleteAccountView`: plain `@State`, no view model, inline error text, `.overlay` progress.
///
/// `FeedRepository.exportMyData()` deliberately returns the server's raw, unparsed bytes so the
/// person receives exactly the document `export_my_data()` produced. This view must never decode
/// and re-encode that JSON — a re-encode changes key order and numeric formatting, so the file
/// would no longer be what the server attested to. It may only *read* a copy of the bytes (via
/// `truncationStatus(of:)`) to detect the `truncated` flag; the bytes handed to `ShareLink` are
/// the exact bytes the repository returned, written straight to a temporary file.
///
/// The document is never rendered on screen — this screen only explains what it contains and
/// hands the file to the share sheet. The file is written into a dedicated, wholly-disposable
/// subdirectory of `tmp` (`exportDirectory`) rather than loose into `tmp` itself: every export
/// this app can produce is a full personal-data dump (including the drink diary, which this
/// project treats as health-adjacent), so its on-disk lifetime is bounded on both ends —
/// `write(_:filename:)` sweeps that whole subdirectory before writing the new file (so a stale
/// file from a previous day/run never just accumulates alongside the new one), and `.onDisappear`
/// sweeps it again when this screen closes. SwiftUI's `ShareLink` has no completion callback in
/// this SDK, so "once sharing finishes" can't be observed directly; bounding lifetime to "at most
/// one file, only while this screen is open or an export is in flight" is the closest available
/// approximation, and it fully closes the reported failure (today's export surviving into
/// tomorrow's).
struct DataExportView: View {
    @Environment(\.container) private var container
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var result: ExportResult?

    struct ExportResult: Equatable {
        let fileURL: URL
        let truncationStatus: TruncationStatus
    }

    /// Three outcomes, not two. Collapsing "decode failed" or "unexpected shape" into "not
    /// truncated" (the previous, buggy behaviour) would silently present a partial or
    /// unverifiable export as complete — precisely the Art. 15 failure the warning exists to
    /// prevent.
    enum TruncationStatus: Equatable {
        /// Decoded successfully; `truncated` was absent (the legitimate demo-stub shape,
        /// `{"demo":true}`) or present and `false`.
        case complete
        /// Decoded successfully; `truncated` was present and `true`.
        case truncated
        /// The document didn't decode as a JSON object, or `truncated` was present but not a
        /// bool (e.g. the string `"true"` or the number `1`). Never claim completeness here.
        case unverifiable
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Label("Download my data", systemImage: "square.and.arrow.down")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.textPrimary)

                Text("""
                Prepares one JSON file containing your profile, privacy settings, pint diary, \
                posts and comments, cheers, friends, blocks placed, reports you've filed, pub \
                preferences, sessions you've hosted or joined, and Nudges sent and received.

                This is your copy of your own data under the DSGVO's right to access and data \
                portability. Nothing in the file is shown on this screen — once it's ready you \
                choose where to save or send it. You can prepare this up to 5 times in any \
                24-hour period.
                """)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textSecondary)

                if let result, let warning = Self.warningMessage(for: result.truncationStatus) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Palette.warning)
                        .accessibilityIdentifier("data-export-warning")
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Palette.warning)
                        .accessibilityIdentifier("data-export-error")
                }

                Button {
                    Task { await export() }
                } label: {
                    Label("Prepare my data export", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(PintButtonStyle())
                .disabled(isExporting)
                .accessibilityIdentifier("data-export-prepare")
                .accessibilityLabel("Prepare my data export")

                if let result {
                    ShareLink(item: result.fileURL) {
                        Label("Save or share the file", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("data-export-share")
                    .accessibilityLabel("Save or share the exported file")
                }
            }
            .padding(Theme.Spacing.lg)
        }
        .pubBackground()
        .navigationTitle("Download my data")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if isExporting { ProgressView().tint(Theme.Palette.accent) } }
        // The view going away is the one lifecycle signal SwiftUI actually gives us for "the
        // person is done with this screen" — see the type doc for why this, not a ShareLink
        // completion, is what bounds the file's lifetime on the "leaving" side.
        .onDisappear { Self.clearExportDirectory() }
    }

    private func export() async {
        guard !isExporting else { return }
        isExporting = true
        errorMessage = nil
        defer { isExporting = false }
        do {
            let data = try await container.feed.exportMyData()
            let url = try Self.write(data, filename: Self.filename())
            result = ExportResult(fileURL: url, truncationStatus: Self.truncationStatus(of: data))
        } catch {
            errorMessage = Self.errorMessage(for: error)
        }
    }

    // MARK: Pure helpers — unit-tested directly (DataExportTests.swift); the view calls these
    // exact functions rather than duplicating their logic inline, so a change that breaks the
    // behaviour they implement also breaks their tests.

    /// Reads the server's `truncated` flag from a *copy* of the bytes via `JSONSerialization` —
    /// never used to produce the bytes written to disk, and never routed through
    /// `SupabaseJSON.decoder`'s `Codable` path, because a `Decodable` `Bool?` field fails the
    /// whole decode (not just that field) when the key is present but the wrong shape, which
    /// would make "present as a string" indistinguishable from "document unparseable" — exactly
    /// the two cases this function must tell apart.
    ///
    /// `truncated` is documented as a `boolean` in the `export_my_data()` contract (`v_truncated
    /// boolean`, `20260812000500_export_my_data.sql`). A value of the *wrong type* for that key
    /// (a string, a number, ...) is therefore anomalous, not an alternate valid spelling of true
    /// or false — coercing `"true"` or `1` into a guessed boolean would mean claiming knowledge
    /// this code doesn't actually have, which is the same category of Art. 15 failure as staying
    /// silent. Anomalous shapes are deliberately routed to `.unverifiable`, not guessed at.
    /// Failing inputs this distinguishes: `"truncated":"true"` (string), `"truncated":1`
    /// (number), a top-level JSON array, and malformed/partial bytes — all `.unverifiable`, none
    /// of them silently `.complete`.
    static func truncationStatus(of data: Data) -> TruncationStatus {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .unverifiable // decode failed, or the top level wasn't a JSON object
        }
        guard let flag = object["truncated"] else {
            return .complete // key absent — the legitimate demo-stub shape, `{"demo":true}`
        }
        // `flag as? Bool` is NOT safe here: Foundation's `NSNumber`/`Bool` bridging treats a
        // plain JSON number (e.g. `1`) as castable to `Bool` too, not only a genuine JSON
        // `true`/`false` — confirmed against this runtime by `testTruncatedAsANumberIsUnverifiableNotCoerced`,
        // which failed against a naive `as? Bool` cast during review. `CFBoolean` (what JSON
        // `true`/`false` actually decodes to) is a distinct `CFTypeID` from `CFNumber` (what a
        // JSON number decodes to), even though both toll-free-bridge to `NSNumber` — checking
        // the underlying CF type is what actually tells them apart.
        guard let number = flag as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return .unverifiable // present but not a genuine JSON bool — anomalous; not coerced
        }
        return number.boolValue ? .truncated : .complete
    }

    /// `nil` means "don't show a warning". The `.unverifiable` copy is deliberately calm — "we
    /// couldn't confirm this is complete", not "your data is corrupted" — because most causes
    /// (a transient decode hiccup) are not evidence anything is actually wrong, only that this
    /// screen can't vouch for completeness the way it normally does.
    static func warningMessage(for status: TruncationStatus) -> String? {
        switch status {
        case .complete:
            return nil
        case .truncated:
            return "This export hit the 10,000-row cap in at least one section, so it's incomplete. " +
                   "Contact support if you need the rest of your data."
        case .unverifiable:
            return "We couldn't confirm this file is complete. If anything looks missing, try " +
                   "preparing your export again."
        }
    }

    /// Maps a failed export to display copy. The RPC's own rate-limit hint
    /// ("Please slow down and try again shortly.") is generic and doesn't tell the person this
    /// specific action resets in 24 hours, so that case gets export-specific, actionable copy
    /// instead of `SupabaseError.friendlyMessage`'s generic fallback.
    static func errorMessage(for error: Error) -> String {
        guard let supabaseError = error as? SupabaseError else {
            return "Couldn't prepare your export. Please try again."
        }
        if case .rateLimited = supabaseError {
            return "You've used all 5 exports allowed today. You can try again tomorrow."
        }
        return supabaseError.friendlyMessage
    }

    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// A stable, dated filename — same instant always yields the same string, and the date
    /// segment changes daily so successive exports don't collide by name.
    static func filename(date: Date = Date()) -> String {
        "cheekypint-export-\(filenameFormatter.string(from: date)).json"
    }

    /// A dedicated, wholly-disposable subdirectory of `tmp` for exported documents — never write
    /// this file loose into `tmp` itself. A full personal-data dump is sensitive enough (this
    /// project already treats the drink diary as health-adjacent) that its on-disk footprint
    /// must be a single, easily-swept location rather than a filename pattern callers have to
    /// remember to match.
    static var exportDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("data-export", isDirectory: true)
    }

    /// Removes the entire export subdirectory, if present. Called before every new export
    /// (sweeping anything left over from a previous run/day — the concrete bug this fixes: export
    /// today, export again tomorrow, and both files used to persist) and from `.onDisappear`
    /// (bounding the file's lifetime to "while this screen is open"). Idempotent: a missing
    /// directory is not an error.
    static func clearExportDirectory() {
        try? FileManager.default.removeItem(at: exportDirectory)
    }

    /// Writes `data` verbatim — no decode, no re-encode — so the file on disk is byte-for-byte
    /// what the repository returned. Always sweeps `exportDirectory` first, so at most one
    /// exported document ever exists on disk at a time.
    @discardableResult
    static func write(_ data: Data, filename: String) throws -> URL {
        clearExportDirectory()
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        let url = exportDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }
}
