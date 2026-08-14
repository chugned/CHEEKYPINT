import SwiftUI
import CheekyPintCore

/// Which of Feed's two transient failures (`FeedViewModel.cheersError`/`deleteError`) the shared
/// `.alert` below is currently showing.
///
/// **Root cause of `docs/STATE_AUDIT.md`'s Cheers finding — and why the "two `.alert` modifiers
/// conflict" hypothesis is *not* it.** That was the natural first suspect (the original code did
/// chain two boolean-driven `.alert`s on the same `Group`, one per error), and collapsing them
/// into this single enum-keyed alert was the first thing tried here. It did not fix anything:
/// with only one `.alert` in the tree, `cheersError`'s failure still never presented, while
/// `deleteError`'s still did — proving the count of `.alert` modifiers was never the variable.
///
/// The actual mechanism, isolated by elimination (each ruled out individually, holding the rest
/// constant): not the number of alerts (one, same result as two); not where the alert is attached
/// (tried the enclosing `Group`, the `List` directly, and per-row — same result every time); not
/// `CheersButton`'s `.animation(value: cheered)` (removed it — same result); not the simultaneous
/// `posts` rollback mutation (removed it too — same result); not raw elapsed time before checking
/// (`Task.sleep`/`Task.yield` for up to 300ms before setting `cheersError` — same result). The one
/// thing that reliably flipped it: whether the tap that leads to the failure passes through a
/// native `Menu`/`confirmationDialog` transition first. `FeedPostCard`'s delete flow does (tap
/// "Post options" → `Menu` → `confirmationDialog`); `CheersButton` is a plain, un-menued `Button`.
/// Proven by swapping the wiring, not just correlation: temporarily making `cheers-toggle` call
/// `onDeletePost` (a plain-button path to the *same, already-working* delete alert) reproduced the
/// silent failure; temporarily making the delete menu item skip its `confirmationDialog` (still
/// inside the `Menu`) did not break it. A real `DispatchQueue.main.asyncAfter` delay of ~0.5s
/// before the alert-driving state change reproduces the same fix `Menu`/`confirmationDialog`
/// provide for free — 0.25s was not enough, 0.5s was, consistently — which points at a SwiftUI/
/// UIKit presentation-transaction timing issue specific to a modal triggered by a plain `Button`'s
/// directly-invoked, detached `Task`, not at anything wrong with `toggleCheers` itself (its
/// rollback logic was already correct — see the audit's "Cheers finding, precisely" section).
///
/// The shipped fix (`content(_:)` below) keeps the single-enum alert (still the right shape for
/// "more than one alert on a view," and no reason to regress it) but drives it from a plain
/// `@State` (`FeedView.presentedAlert`) populated via `.onChange`, with the ~0.5s deferral applied
/// only to the Cheers path — `deleteError` needs none, since its own `Menu`/`confirmationDialog`
/// already provides the gap.
private enum FeedAlert: Equatable {
    case cheers(String)
    case delete(String)

    var title: String {
        switch self {
        case .cheers: return "Couldn't update Cheers"
        case .delete: return "Couldn't delete that post"
        }
    }

    var message: String {
        switch self {
        case .cheers(let message), .delete(let message): return message
        }
    }
}

/// The friends-only feed. A `List` of `FeedPostCard`s with pull-to-refresh, infinite scroll, and
/// the loading/error/empty states every screen needs (master prompt §22).
struct FeedView: View {
    @Environment(\.container) private var container
    @State private var model: FeedViewModel?
    @State private var showCompose = false
    /// Mirrors `model.cheersError`/`model.deleteError` via the `.onChange` in `content(_:)` rather
    /// than being read live inside the `.alert`'s own `isPresented`/`presenting` closures. See
    /// `FeedAlert`'s doc for why: reading `@Observable` state directly from those closures is what
    /// silently failed to present.
    @State private var presentedAlert: FeedAlert?

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    content(model)
                } else {
                    ProgressView().tint(Theme.Palette.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .pubBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Wordmark(scale: .header)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showCompose = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .disabled(model == nil)
                    .accessibilityIdentifier("feed-compose")
                    .accessibilityLabel("Compose a post")
                }
            }
            .sheet(isPresented: $showCompose) {
                ComposePostSheet(onPosted: { await model?.reload() })
            }
        }
        .task {
            if let model {
                // `.task` is cancelled when the tab is switched away from and re-runs when it
                // reappears (this is what made the cancellation bug reachable at all — see
                // `FeedViewModel.fetchFirstPage()`'s cancellation catch). If the reappearing
                // screen has nothing loaded and isn't already loading, retry: this covers both a
                // load that was cancelled mid-flight (which leaves `loadError` untouched, so it
                // wouldn't otherwise be retried) and a genuine failure the user backed out of
                // without tapping Retry.
                if model.posts.isEmpty, !model.isLoading {
                    await model.load()
                }
            } else {
                let vm = FeedViewModel(container: container)
                model = vm
                await vm.load()
            }
        }
    }

    @ViewBuilder
    private func content(_ model: FeedViewModel) -> some View {
        @Bindable var model = model
        Group {
            if model.isLoading && model.posts.isEmpty {
                ProgressView().tint(Theme.Palette.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.loadError, model.posts.isEmpty {
                StatusView(systemImage: Self.errorIcon(for: error), title: "Couldn't load the feed",
                           message: error.friendlyMessage, actionTitle: "Retry") {
                    Task { await model.load() }
                }
            } else if model.posts.isEmpty {
                // A friends-only feed is legitimately empty for a new user with no friends yet —
                // that's not an error, so this points them at the fix instead of spinning forever
                // or saying nothing more than "No posts".
                StatusView(systemImage: "person.2.slash",
                           title: "Nothing here yet",
                           message: "Your feed shows posts from friends. Add a friend to start seeing their pints here.")
            } else {
                List {
                    ForEach(model.posts) { post in
                        FeedPostCard(
                            post: post,
                            avatarURL: container.avatarURL(for: post.post.avatarPath),
                            imageURL: container.profiles.postImageURL(for: post.post.imagePath),
                            onToggleCheers: { Task { await model.toggleCheers(post) } },
                            onCommentCountChanged: { model.applyCommentCountDelta(postID: post.id, delta: $0) },
                            onDeletePost: { Task { await model.deletePost(post) } }
                        )
                        .listRowInsets(EdgeInsets(top: Theme.Spacing.xs, leading: Theme.Spacing.md,
                                                   bottom: Theme.Spacing.xs, trailing: Theme.Spacing.md))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .onAppear {
                            guard post.id == model.posts.last?.id else { return }
                            Task { await model.loadMore() }
                        }
                    }
                    pagingFooter(model)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable { await model.refresh() }
            }
        }
        // `presentedAlert` is a plain `@State` on `FeedView`, populated from `model.cheersError`/
        // `deleteError` by the two `.onChange`s below, rather than the `.alert` reading those
        // `@Observable` properties live through a computed `Binding` — see `FeedAlert`'s doc for
        // the elimination process this came out of. `deleteError` needs no extra deferral: its
        // `Menu`/`confirmationDialog` already provides the transaction gap. `cheersError` does —
        // `Self.cheersAlertDeferral` — because `CheersButton` is a plain `Button` with no such
        // gap of its own.
        .onChange(of: model.cheersError) { _, newValue in
            guard let newValue else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.cheersAlertDeferral) {
                presentedAlert = .cheers(newValue)
            }
        }
        .onChange(of: model.deleteError) { _, newValue in
            guard let newValue else { return }
            presentedAlert = .delete(newValue)
        }
        .alert(presentedAlert?.title ?? "", isPresented: Binding(
            get: { presentedAlert != nil },
            set: { isPresented in
                guard !isPresented else { return }
                presentedAlert = nil
                model.cheersError = nil
                model.deleteError = nil
            }
        ), presenting: presentedAlert) { _ in
            Button("OK", role: .cancel) {
                presentedAlert = nil
                model.cheersError = nil
                model.deleteError = nil
            }
        } message: { alert in
            Text(alert.message)
        }
    }

    /// How long `cheersError` waits before promoting itself to `presentedAlert` (see the
    /// `.onChange` above and `FeedAlert`'s doc for why). Empirically, 0.25s was not enough and
    /// 0.5s was, consistently, across repeated runs — this leaves headroom above that observed
    /// threshold rather than shipping the exact boundary value.
    private static let cheersAlertDeferral: TimeInterval = 0.5

    // MARK: - Pure helper (unit tested; see FeedViewTests)

    /// Distinguishes the full-screen error icon by cause, matching `DataExportView
    /// .errorMessage(for:)`'s standard for honest, correctly-attributed copy
    /// (`DataExportView.swift:209-217`). The words were already honest here
    /// (`SupabaseError.friendlyMessage` never claims offline for a rate limit), but every case
    /// shared the same `wifi.slash` icon, so a throttled user saw the universal "no internet" glyph
    /// next to "That's a lot at once" and had every reason to go check their router
    /// (`docs/STATE_AUDIT.md`'s Low finding on Feed's error `StatusView`).
    static func errorIcon(for error: SupabaseError) -> String {
        switch error {
        case .offline:
            return "wifi.slash"
        case .rateLimited:
            return "hourglass"
        case .notAuthenticated, .forbidden:
            return "lock"
        case .notFound:
            return "questionmark.circle"
        case .validation, .server, .decoding, .unknown:
            return "exclamationmark.triangle"
        }
    }

    /// A failed `loadMore` used to be invisible (nothing showed while `posts` was non-empty) and
    /// unretryable (no control to trigger it again short of scrolling away and back). This row
    /// covers both paging states the initial-load states above don't: in flight, and failed with
    /// a way to retry.
    @ViewBuilder
    private func pagingFooter(_ model: FeedViewModel) -> some View {
        if model.isLoading {
            HStack {
                Spacer()
                ProgressView().tint(Theme.Palette.accent)
                Spacer()
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } else if model.loadError != nil, model.hasMore {
            HStack {
                Spacer()
                Button("Retry") { Task { await model.loadMore() } }
                    .buttonStyle(.bordered)
                Spacer()
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }
}
