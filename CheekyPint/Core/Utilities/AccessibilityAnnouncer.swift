import UIKit

/// Speaks VoiceOver-only feedback for inline status text that has no live-region API at our iOS
/// 17 floor. SwiftUI never announces a sibling view's appearance on its own unless focus moves
/// there, so the five inline error/success `Text`s across `ComposePostSheet`, `PostCommentsSheet`,
/// `ReportContentView` and `DataExportView` were previously silent — a VoiceOver user who tapped
/// Send/Post/Prepare and hit a failure got no spoken feedback at all.
///
/// `UIAccessibility.post(notification:.announcement, argument:)` has no dedup of its own: calling
/// it from every body re-render, or from a plain `.onChange` that happens to fire twice with the
/// *same* text (e.g. two consecutive Send attempts that both hit the identical offline error),
/// would nag with the identical sentence repeatedly — worse than the original silence, per the
/// audit. This type keeps one thing in memory — the last message it actually spoke — and skips
/// announcing again until the text genuinely changes. A transition to `nil` (the message clearing,
/// e.g. a retry that starts by resetting `errorMessage = nil`) is never itself announced and never
/// overwrites that memory, so the *next* non-nil message is still checked against whatever was
/// last actually spoken, not against "nothing" — otherwise clearing-then-reshowing the identical
/// error would look "new" again and re-announce it.
///
/// One instance is meant to live in a view's `@State`, mutated from that view's own `.onChange`
/// handlers — see `ComposePostSheet`, `PostCommentsSheet`, `ReportContentView`, `DataExportView`.
/// `@MainActor` because `UIAccessibility.post` is (`NS_SWIFT_UI_ACTOR`) — every call site is
/// already main-actor code (SwiftUI view state/`.onChange`), so this makes that explicit instead
/// of hopping asynchronously on every call.
@MainActor
struct AccessibilityAnnouncer {
    private(set) var lastAnnounced: String?
    /// Injectable so `AccessibilityAnnouncerTests.swift` can spy on what actually got posted,
    /// matching this codebase's usual seam style (e.g. `ReportContentView.report`'s injected
    /// repository closures) rather than only testing the decision logic in isolation.
    private let post: (String) -> Void

    init(post: @escaping (String) -> Void = { UIAccessibility.post(notification: .announcement, argument: $0) }) {
        self.post = post
    }

    /// The pure decision, split out so it's directly unit-testable without touching
    /// `UIAccessibility` (`AccessibilityAnnouncerTests.swift`): `nil`/empty never qualify, and
    /// a message identical to what was last announced never qualifies either. `nonisolated`: it
    /// touches no main-actor state, so a test can call it directly with no actor hop.
    nonisolated static func shouldAnnounce(_ message: String?, lastAnnounced: String?) -> Bool {
        guard let message, !message.isEmpty else { return false }
        return message != lastAnnounced
    }

    /// Announces `message` via VoiceOver if `shouldAnnounce` says it's genuinely new, and records
    /// it as the last-announced text either way that it qualifies. Call from a `.onChange` of the
    /// value in question — never from `body` directly, which would fire on every render.
    mutating func announce(_ message: String?) {
        guard let message, Self.shouldAnnounce(message, lastAnnounced: lastAnnounced) else { return }
        lastAnnounced = message
        post(message)
    }
}
