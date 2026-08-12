import SwiftUI
import CheekyPintCore

/// What `ReportContentView` is reporting. One view handles both call sites (`FeedPostCard`'s post
/// menu, `PostCommentsSheet`'s per-comment menu) rather than two near-identical screens.
///
/// `.post` carries `hasPhoto` (not just the id) because the sensible default category differs for
/// a post with a photo versus a text-only one — see `ReportContentView.defaultCategory(for:)`.
/// A comment carries no photo of its own, so `.comment` needs only its id.
enum ReportTarget: Equatable {
    case post(id: UUID, hasPhoto: Bool)
    case comment(id: UUID)
}

/// Report a post or a comment (moderation affordance, mirroring `ReportUserView`'s structure for
/// users — same `Form`/`Picker`/optional-details/`sent`-confirmation/inline-error/Cancel-Send
/// shape).
///
/// **Demo mode's report calls are no-ops that keep no record**
/// (`FeedRepository.reportPost`/`reportComment` early-return when `DemoWorld.shared.isActive`),
/// and even in live mode this view only ever learns that the call did not throw — never that a
/// human reviewed anything, that content was removed, or that the reporter will be notified of an
/// outcome. The confirmation copy below is deliberately the same register as `ReportUserView`'s:
/// "we received this", nothing more.
struct ReportContentView: View {
    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss

    let target: ReportTarget

    @State private var category: ReportCategory
    @State private var details = ""
    @State private var isSending = false
    @State private var sent = false
    @State private var errorMessage: String?

    init(target: ReportTarget) {
        self.target = target
        _category = State(initialValue: Self.defaultCategory(for: target))
    }

    /// `.inappropriatePostImage` when the reported post actually carries a photo,
    /// `.inappropriateText` for a text-only post or any comment. Pure and `static` so the default
    /// is directly assertable without constructing a view (see `ReportContentTests`).
    static func defaultCategory(for target: ReportTarget) -> ReportCategory {
        switch target {
        case .post(_, let hasPhoto): return hasPhoto ? .inappropriatePostImage : .inappropriateText
        case .comment: return .inappropriateText
        }
    }

    /// The routing core: calls exactly one of `reportPost`/`reportComment`, depending on `target`
    /// — never both, never neither. Free of `container` and `@State`, so a test can inject two
    /// spy closures and observe which one actually fired: the gate that catches "both targets
    /// happen to call the same repository method", which an assertion of merely "no error thrown"
    /// would miss entirely.
    static func report(
        target: ReportTarget, category: ReportCategory, details: String?,
        reportPost: (UUID, ReportCategory, String?) async throws -> Void,
        reportComment: (UUID, ReportCategory, String?) async throws -> Void
    ) async throws {
        switch target {
        case .post(let id, _):
            try await reportPost(id, category, details)
        case .comment(let id):
            try await reportComment(id, category, details)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Reason") {
                    Picker("Reason", selection: $category) {
                        ForEach(ReportCategory.allCases, id: \.self) { option in
                            Text(option.displayName).font(Theme.Typography.body).tag(option)
                        }
                    }
                    .accessibilityIdentifier("report-content-reason")
                    .accessibilityLabel("Reason")
                }
                Section("Details (optional)") {
                    TextField("Anything we should know?", text: $details, axis: .vertical)
                        .font(Theme.Typography.body)
                        .lineLimit(3...6)
                        .accessibilityIdentifier("report-content-details")
                        .accessibilityLabel("Details")
                }
                if sent {
                    Label("Thanks — our team will take a look.", systemImage: "checkmark.circle.fill")
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Palette.success)
                        .accessibilityIdentifier("report-content-sent")
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Palette.warning)
                        .accessibilityIdentifier("report-content-error")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.backgroundPrimary)
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("report-content-cancel")
                        .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { Task { await send() } }
                        .disabled(isSending || sent)
                        .accessibilityIdentifier("report-content-send")
                        .accessibilityLabel("Send report")
                }
            }
        }
    }

    private var navigationTitle: String {
        switch target {
        case .post: return "Report post"
        case .comment: return "Report comment"
        }
    }

    private func send() async {
        isSending = true; errorMessage = nil
        defer { isSending = false }
        do {
            try await Self.report(
                target: target, category: category, details: details.isEmpty ? nil : details,
                reportPost: { try await container.feed.reportPost($0, category: $1, details: $2) },
                reportComment: { try await container.feed.reportComment($0, category: $1, details: $2) }
            )
            sent = true
            try? await Task.sleep(for: .seconds(1))
            dismiss()
        } catch let error as SupabaseError {
            errorMessage = error.friendlyMessage
        } catch {
            errorMessage = "Please try again."
        }
    }
}
