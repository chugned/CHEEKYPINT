import SwiftUI

/// DSGVO Art. 15 (access) / Art. 20 (portability) self-service export. Structured like
/// `DeleteAccountView`: plain `@State`, no view model, inline error text, `.overlay` progress.
///
/// `FeedRepository.exportMyData()` deliberately returns the server's raw, unparsed bytes so the
/// person receives exactly the document `export_my_data()` produced. This view must never decode
/// and re-encode that JSON — a re-encode changes key order and numeric formatting, so the file
/// would no longer be what the server attested to. It may only *read* the bytes (via
/// `isTruncated(_:)`) to detect the `truncated` flag; the bytes handed to `ShareLink` are the
/// exact bytes the repository returned, written straight to a temporary file.
///
/// The document is never rendered on screen — this screen only explains what it contains and
/// hands the file to the share sheet.
struct DataExportView: View {
    @Environment(\.container) private var container
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var result: ExportResult?

    struct ExportResult: Equatable {
        let fileURL: URL
        let truncated: Bool
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

                if let result, let warning = Self.warningMessage(forTruncated: result.truncated) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Palette.warning)
                        .accessibilityIdentifier("data-export-truncated-warning")
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
    }

    private func export() async {
        guard !isExporting else { return }
        isExporting = true
        errorMessage = nil
        defer { isExporting = false }
        do {
            let data = try await container.feed.exportMyData()
            let url = try Self.write(data, filename: Self.filename())
            result = ExportResult(fileURL: url, truncated: Self.isTruncated(data))
        } catch {
            errorMessage = Self.errorMessage(for: error)
        }
    }

    // MARK: Pure helpers — unit-tested directly (DataExportTests.swift); the view calls these
    // exact functions rather than duplicating their logic inline, so a change that breaks the
    // behaviour they implement also breaks their tests.

    /// Detects the server's `truncated` flag by decoding *only* that one key, never the full
    /// document — this is a read for display purposes only and is never used to produce the
    /// bytes written to disk. A missing key (e.g. demo mode's `{"demo":true}` stub) reads as
    /// "not truncated" rather than crashing or defaulting to true.
    static func isTruncated(_ data: Data) -> Bool {
        struct Probe: Decodable { let truncated: Bool? }
        return (try? SupabaseJSON.decoder.decode(Probe.self, from: data))?.truncated ?? false
    }

    /// `nil` means "don't show a warning"; any other value is the exact copy to display.
    static func warningMessage(forTruncated truncated: Bool) -> String? {
        guard truncated else { return nil }
        return "This export hit the 10,000-row cap in at least one section, so it's incomplete. " +
               "Contact support if you need the rest of your data."
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

    /// Writes `data` verbatim — no decode, no re-encode — so the file on disk is byte-for-byte
    /// what the repository returned.
    @discardableResult
    static func write(_ data: Data, filename: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }
}
