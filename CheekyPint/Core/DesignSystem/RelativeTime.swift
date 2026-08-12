import Foundation

/// The app's two relative-time formatters, built once and shared.
///
/// `RelativeDateTimeFormatter` is expensive to construct, so it must never be created inside a
/// SwiftUI `body`, which is re-evaluated often. `FeedPostCard` and `PostCommentsSheet` each held a
/// verbatim copy of both of these as private statics; the pair is one presentation decision (how
/// this app spells a timestamp on screen and how it reads it aloud), so it lives in one place.
/// `@MainActor` because `RelativeDateTimeFormatter` is not `Sendable`. These formatters were
/// previously `private static let`s on `FeedPostCard`/`PostCommentsSheet`, which are `View`s and so
/// already inherit `@MainActor` from SwiftUI's `@MainActor protocol View` — that inference is what
/// made the originals legal under `SWIFT_STRICT_CONCURRENCY: complete`. A bare `enum` has no such
/// conformance to inherit it from, so the isolation has to be stated. Both call sites are view
/// bodies, so nothing has to change to reach it.
@MainActor
enum RelativeTime {
    /// For visible captions: "30 min. ago" rather than `Text(_:style: .relative)`'s compound
    /// "30 min, 7 secs" / "1 hr, 30 min" form.
    static let caption: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// The same instant spelled out in full, for VoiceOver: an abbreviated unit read aloud
    /// ("30 min ago") is worse than the whole word ("30 minutes ago"), so accessibility labels use
    /// this one rather than the visible text.
    static let accessibility: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}
