import Foundation

#if DEBUG
/// Deterministic fault injection for UI tests, driven entirely by launch arguments — never by
/// touching the simulator's real network or its privacy settings. Generalises the single-purpose
/// `-uiTestForceOffline` hook that used to live in `FeedRepository.addComment` (it covered exactly
/// one call) into something that can fail, or force-empty, *any* repository operation this app
/// has, individually.
///
/// **Where this is called from matters.** Every call site is at the top of a repository method,
/// before that method's own `if await DemoWorld.shared.isActive { … }` branch — the same position
/// `addComment`'s original hook occupied. That is deliberate: it is the one point every read and
/// write already passes through regardless of whether the app is running against demo data or a
/// real backend, so a UI test can still launch with `-uiTestDemo` (deterministic, no database) and
/// still reach an error or an empty-success state on demand. Putting the check one layer down, in
/// `SupabaseData`, would miss every demo-mode call site entirely — demo mode never reaches
/// `SupabaseData`. Putting it one layer up, in a view model or a view, would mean duplicating the
/// same `if` in every screen that wants to test failure instead of once here, which is the exact
/// shape this file exists to avoid ("sprinkling copies of the same `if` into ten methods").
///
/// Two independent axes, because "empty" and "error" are different states with different UI: an
/// empty result is a *successful* response with nothing in it, while an error is a thrown
/// `SupabaseError` — collapsing them into one boolean would force every empty-state test to
/// masquerade as an error-swallowing test instead (several call sites, e.g.
/// `PostCommentsViewModel.load()`'s friends fetch, do swallow errors into `[]`, but relying on
/// that as the *only* route to an empty state conflates two different code paths under test).
///
/// Compiled out of Release entirely — the whole file is `#if DEBUG` — and a complete no-op at
/// every call site when neither launch argument is present, so leaving the calls in place has no
/// effect on real usage. See `DebugFaultInjectorTests` for the parsing rules this documents.
enum DebugFaultInjector {
    /// Operation names this app's repositories currently register, so a call site and a test
    /// can't silently drift apart on a typo'd string with no compiler to catch it. Not exhaustive
    /// of every repository method — only the ones a screen in `docs/STATE_AUDIT.md`'s scope needs
    /// to fail; add here first, then use at the call site.
    ///
    /// `feedPage`/`postComments` are split into `.initial`/`.loadMore` (the call site picks which,
    /// keyed by whether it was passed a cursor) because a single flat name can't distinguish "fail
    /// the first page" from "fail the *next* page" — and the whole point of "fail a specific
    /// operation, not everything at once" is being able to let the first page succeed (so there's
    /// something on screen to scroll) while only the paginated call fails, which is what makes a
    /// failed `loadMore` distinguishable from having simply reached the end.
    enum Operation {
        static let feedPageInitial = "feedPage.initial"
        static let feedPageLoadMore = "feedPage.loadMore"
        static let toggleCheers = "toggleCheers"
        static let createPost = "createPost"
        static let deletePost = "deletePost"
        static let postCommentsInitial = "postComments.initial"
        static let postCommentsLoadMore = "postComments.loadMore"
        static let addComment = "addComment"
        static let deleteComment = "deleteComment"
        static let reportPost = "reportPost"
        static let reportComment = "reportComment"
        static let reportUser = "reportUser"
        static let exportMyData = "exportMyData"
        static let fetchFriends = "fetchFriends"
        /// `PlaceCompleter`'s live `MKLocalSearchCompleter` suggestions, not a `SupabaseRepository`
        /// call — `MKLocalSearchCompleter` talks to Apple's own servers, so there is no repository
        /// boundary to hang `throwIfFaulted` on the way every operation above does. `PlaceCompleter`
        /// checks this and `isFaulted(_:)` directly, before it ever touches its real
        /// `MKLocalSearchCompleter`, so a UI test can force "found nothing" or "the search itself
        /// failed" deterministically instead of depending on the test environment's actual network
        /// reachability (see `docs/STATE_AUDIT.md`'s PlacePickerSheet finding).
        static let placeSearch = "placeSearch"
    }

    /// `ProcessInfo.arguments` cannot change after launch, so these are parsed once, not
    /// re-parsed on every repository call.
    private static let arguments = ProcessInfo.processInfo.arguments
    private static let failingOperations = Set(values(after: "-uiTestFailOperation", in: arguments))
    private static let forcedEmptyOperations = Set(values(after: "-uiTestForceEmpty", in: arguments))
    private static let errorKind = values(after: "-uiTestFailError", in: arguments).first ?? "server"

    /// The flag's value is the next argument verbatim, split on commas — `-uiTestFailOperation
    /// createPost,addComment` fails both in one launch, for a test that needs to prove two
    /// different actions fail *independently* of one another in the same screen. A pure function
    /// of its argument array (not `ProcessInfo` directly) so it's unit-testable without relaunching
    /// a process — see `DebugFaultInjectorTests`.
    static func values(after flag: String, in arguments: [String]) -> [String] {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return [] }
        return arguments[index + 1].split(separator: ",").map(String.init)
    }

    /// Call at the top of a repository method that can meaningfully fail. Throws the
    /// `-uiTestFailError`-configured `SupabaseError` if, and only if, `operation` was named in
    /// `-uiTestFailOperation`; otherwise a no-op, so every call site is safe to leave in place
    /// permanently rather than being torn out after each investigation.
    static func throwIfFaulted(_ operation: String) throws {
        guard failingOperations.contains(operation) else { return }
        throw error(for: errorKind)
    }

    /// Call at the top of a **read** repository method, before it decides demo vs. live, for a
    /// method whose empty state can't otherwise be reached from a UI test — e.g.
    /// `FeedRepository.page`'s demo branch always returns a fixed, non-empty seed; there is no
    /// query parameter that makes it return nothing. Returns `true` exactly when `operation` was
    /// named in `-uiTestForceEmpty`; the call site is responsible for returning the empty value
    /// itself (`[]`, typically), since this type has no way to know the caller's element type.
    static func isForcedEmpty(_ operation: String) -> Bool {
        forcedEmptyOperations.contains(operation)
    }

    /// Whether `operation` was named in `-uiTestFailOperation`, without throwing anything.
    /// `throwIfFaulted` above is the right call at any site that already throws `SupabaseError` —
    /// it folds "should this fail" and "with which error" into one call. `PlaceCompleter`'s search
    /// isn't a `SupabaseError`-shaped operation at all (it's a `MKLocalSearchCompleter` callback,
    /// not an async throwing repository method), so it needs the boolean on its own to decide
    /// between its own two non-`SupabaseError` outcomes (`.noMatches` / `.failed`).
    static func isFaulted(_ operation: String) -> Bool {
        failingOperations.contains(operation)
    }

    /// Maps the `-uiTestFailError` string to the `SupabaseError` it names. Deliberately small and
    /// exhaustive-by-default (falls back to `.server`, the least specific real case) rather than
    /// failing the launch on a typo — a UI test that misspells this argument should get a
    /// visibly-present but wrong error state, not a crash before the app has even rendered.
    ///
    /// `.rateLimited`'s hint is left `nil` on purpose: the one screen in scope that gives
    /// rate-limiting its own copy (`DataExportView.errorMessage(for:)`) branches on the *case*,
    /// not the hint text, so fabricating a realistic-sounding hint here would be effort spent on
    /// a value nothing actually reads.
    static func error(for kind: String) -> SupabaseError {
        switch kind {
        case "offline": return .offline
        case "notAuthenticated": return .notAuthenticated
        case "rateLimited": return .rateLimited(hint: nil)
        case "forbidden": return .forbidden
        case "notFound": return .notFound
        default: return .server(status: 500, message: "Internal Server Error")
        }
    }
}
#endif
