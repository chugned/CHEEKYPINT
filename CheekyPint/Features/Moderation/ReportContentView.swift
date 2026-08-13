import SwiftUI
import CheekyPintCore

/// What `ReportContentView` is reporting. One view handles all three call sites (`FeedPostCard`'s
/// post menu, `PostCommentsSheet`'s per-comment menu, `FriendProfileView`'s profile menu) rather
/// than three near-identical screens.
///
/// `.post` carries `hasPhoto` (not just the id) because the sensible default category differs for
/// a post with a photo versus a text-only one — see `ReportContentView.defaultCategory(for:)`.
/// A comment carries no photo of its own, so `.comment` needs only its id; likewise `.user`.
///
/// `.user` used to be a separate `ReportUserView`. Keeping the two screens apart is what let the
/// user-report path miss every fix the content paths got — details sanitising, the 1000-code-point
/// bound and its counter, and the double-tap `guard` — while writing the same `reports.details`
/// column for the same human moderator. One view, one `send()`, so the three targets cannot drift
/// again; only the repository call differs, and that difference lives in `report(target:…)`.
enum ReportTarget: Equatable {
    case post(id: UUID, hasPhoto: Bool)
    case comment(id: UUID)
    case user(id: UUID)
}

/// Report a post, a comment, or a user (moderation affordance, master prompt §19). Queues a
/// moderation report server-side.
///
/// **Demo mode's report calls are no-ops that keep no record**
/// (`FeedRepository.reportPost`/`reportComment` and `FriendsRepository.report` early-return when
/// `DemoWorld.shared.isActive`), and even in live mode this view only ever learns that the call did
/// not throw — never that a human reviewed anything, that content was removed, or that the reporter
/// will be notified of an outcome. The confirmation copy below is deliberately in that register:
/// "we received this", nothing more.
struct ReportContentView: View {
    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss

    /// Mirrors all three report RPCs' `left(…, 1000)` — `report_post`/`report_comment`
    /// (`20260811000700_rpc_feed_reports.sql`) and `report_user`
    /// (`20260101000800_rpc_social.sql`), which all write `reports.details`, itself
    /// `check (char_length(details) <= 1000)`.
    static let detailsLimit = 1000

    /// Shared with the composers' reasoning: the counter and the Send gate must measure what will
    /// be **stored**, in the code points Postgres counts — see `ProfileTextSanitizer`.
    private static let sanitizer = ProfileTextSanitizer()

    /// Cleans the free-text details before they leave the device.
    ///
    /// Why this column in particular: `reports.details` is read by a **human moderator** deciding
    /// whether reported text is abusive, so a bidi-override or zero-width payload in the details is
    /// aimed at the person adjudicating it. Every column in the app that stores text a user typed now
    /// gets the same treatment — the last two, `pub_sessions.name` and `pint_entries.private_note`,
    /// followed in `CreateSessionView`/`LogPintSheet`. The server halves —
    /// `strip_ugc_control_chars` in `report_post`, `report_comment`, `report_user`,
    /// `create_pub_session` and `create_pint_entry` — are pinned by `t43e`/`t43f`/`t53`/`t54` in
    /// `supabase/tests/rls_rpc_suite.sql`. (The six `profiles` columns are sanitised client-side only:
    /// they are written by a plain PostgREST `PATCH`, so there is no server-side hook to add.)
    ///
    /// Returns `nil` for empty input: whitespace-only details are nothing to tell a moderator, and
    /// `nil` keeps them out of the column rather than storing an empty string.
    static func sanitizedDetails(_ raw: String) -> String? {
        let clean = sanitizer.sanitize(raw, allowNewlines: true, maxLength: detailsLimit)
        return clean.isEmpty ? nil : clean
    }

    /// How long the details will be once stored, for the live counter.
    static func detailsLength(of raw: String) -> Int {
        sanitizer.sanitizedLength(raw, allowNewlines: true)
    }

    /// Details are optional, so the only thing this gates is the upper bound — and it disables Send
    /// past the limit rather than letting `left(…, 1000)` drop the tail, for the same reason the
    /// two composers do: a report whose last paragraph vanished silently is worse than a report
    /// the user was told to shorten.
    static func detailsWithinLimit(_ raw: String) -> Bool {
        detailsLength(of: raw) <= detailsLimit
    }

    let target: ReportTarget

    @State private var category: ReportCategory
    @State private var details = ""
    @State private var isSending = false
    @State private var sent = false
    @State private var errorMessage: String?
    /// See `AccessibilityAnnouncer`'s doc — speaks `errorMessage`/the sent confirmation for
    /// VoiceOver, deduped so a retry that hits the identical error doesn't nag.
    @State private var announcer = AccessibilityAnnouncer()

    init(target: ReportTarget) {
        self.target = target
        _category = State(initialValue: Self.defaultCategory(for: target))
    }

    /// `.inappropriatePostImage` when the reported post actually carries a photo,
    /// `.inappropriateText` for a text-only post, any comment, or a user (the value the standalone
    /// user-report screen started on). Pure and `static` so the default is directly assertable
    /// without constructing a view (see `ReportContentTests`).
    static func defaultCategory(for target: ReportTarget) -> ReportCategory {
        switch target {
        case .post(_, let hasPhoto): return hasPhoto ? .inappropriatePostImage : .inappropriateText
        case .comment, .user: return .inappropriateText
        }
    }

    /// The routing core: calls exactly one of `reportPost`/`reportComment`/`reportUser`, depending
    /// on `target` — never two, never none. Free of `container` and `@State`, so a test can inject
    /// three spy closures and observe which one actually fired: the gate that catches "two targets
    /// happen to call the same repository method", which an assertion of merely "no error thrown"
    /// would miss entirely.
    static func report(
        target: ReportTarget, category: ReportCategory, details: String?,
        reportPost: (UUID, ReportCategory, String?) async throws -> Void,
        reportComment: (UUID, ReportCategory, String?) async throws -> Void,
        reportUser: (UUID, ReportCategory, String?) async throws -> Void
    ) async throws {
        switch target {
        case .post(let id, _):
            try await reportPost(id, category, details)
        case .comment(let id):
            try await reportComment(id, category, details)
        case .user(let id):
            try await reportUser(id, category, details)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                // At the top of the Form, matching `ComposePostSheet`'s own status-text
                // placement — not at the bottom, where they sat before. Screenshotting this
                // screen at accessibility XXL found the bottom placement meant the "sent"
                // confirmation rendered entirely below the fold: the Reason and Details sections
                // alone already exceed one screen's height at that text size, and `send()`
                // dismisses the sheet only ~1s after `sent` flips true — nowhere near enough time
                // for a sighted user to scroll down and actually see it. Top placement means it's
                // visible immediately, with no scrolling, regardless of text size.
                if sent {
                    // See `PostCommentsSheet.swift`'s comment on `comments-send-error` — that
                    // sibling was found ellipsis-truncated at accessibility XXL under a height
                    // squeeze the code review alone hadn't caught. Applied here too, defensively.
                    Label("Thanks — our team will take a look.", systemImage: "checkmark.circle.fill")
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Palette.success)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("report-content-sent")
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("report-content-error")
                }
                Section("Reason") {
                    // `.navigationLink`, not the Form default (an inline menu-style row: the
                    // selected value squeezed next to a chevron on the same line as "Reason").
                    // At accessibility XXL the longest categories ("Inappropriate profile image")
                    // middle-truncated to illegible fragments like "Inappr…te text" in that
                    // cramped space. `.navigationLink` pushes to a dedicated screen where each
                    // option is its own full-width row — free to wrap onto a second line instead
                    // of truncating — and the summary row's own selected-value text gets the same
                    // benefit, since it no longer shares a line with the section header text.
                    // Confirmed by screenshot at XXL, not just style choice — see
                    // `docs/ACCESSIBILITY_AUDIT.md`.
                    Picker("Reason", selection: $category) {
                        ForEach(ReportCategory.allCases, id: \.self) { option in
                            Text(option.displayName).font(Theme.Typography.body).tag(option)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    .accessibilityIdentifier("report-content-reason")
                    .accessibilityLabel("Reason")
                }
                Section("Details (optional)") {
                    TextField("Anything we should know?", text: $details, axis: .vertical)
                        .font(Theme.Typography.body)
                        .lineLimit(3...6)
                        .accessibilityIdentifier("report-content-details")
                        .accessibilityLabel("Details")
                    HStack {
                        Spacer(minLength: 0)
                        // `verbatim:` matters here. `Text("\(int)")` goes through
                        // `LocalizedStringKey`, which formats the number for the current locale —
                        // on a German device that rendered this counter as "0/1.000", which reads
                        // as a decimal. A character counter wants bare digits. The two composer
                        // counters use `verbatim:` for the same reason; their limits (500/280) just
                        // happen to sit below the grouping threshold, so it never showed there.
                        Text(verbatim: "\(detailsLength)/\(Self.detailsLimit)")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(isOverLimit ? Theme.Palette.warning : Theme.Palette.textSecondary)
                            .accessibilityIdentifier("report-content-details-counter")
                            .accessibilityLabel("\(detailsLength) of \(Self.detailsLimit) characters used")
                    }
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
                        .disabled(isSending || sent || isOverLimit)
                        .accessibilityIdentifier("report-content-send")
                        .accessibilityLabel("Send report")
                }
            }
        }
        // See `AccessibilityAnnouncer`'s doc. Two sources, one announcer: the two texts are never
        // the same string, and both dedup against the same "last spoken" memory correctly either
        // way.
        .onChange(of: errorMessage) { _, new in announcer.announce(new) }
        .onChange(of: sent) { _, new in
            guard new else { return }
            announcer.announce("Thanks — our team will take a look.")
        }
    }

    private var navigationTitle: String {
        switch target {
        case .post: return "Report post"
        case .comment: return "Report comment"
        case .user: return "Report user"
        }
    }

    private var detailsLength: Int { Self.detailsLength(of: details) }

    private var isOverLimit: Bool { !Self.detailsWithinLimit(details) }

    private func send() async {
        // `.disabled` alone is the weaker guard: the Button's action fires from its own `Task`, and
        // SwiftUI can dispatch a second tap before the first re-render flips `isSending`, so a
        // double-tap could file two reports. Every other write surface in this feature checks the
        // flag in the action too (`ComposePostSheet.submit`, `DataExportView.export`,
        // `PostCommentsViewModel.send`/`delete`); neither report screen did.
        guard !isSending, !sent else { return }
        isSending = true; errorMessage = nil
        defer { isSending = false }
        do {
            try await Self.report(
                target: target, category: category, details: Self.sanitizedDetails(details),
                reportPost: { try await container.feed.reportPost($0, category: $1, details: $2) },
                reportComment: { try await container.feed.reportComment($0, category: $1, details: $2) },
                reportUser: { try await container.friends.report($0, category: $1, details: $2) }
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
