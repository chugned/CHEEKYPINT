import SwiftUI
import CheekyPintCore

/// `FeedViewModel.deleteError`'s presentation, kept as a single-case enum (rather than a plain
/// `Bool`/`String?` pair) because that shape is still the right one for "more than one alert on a
/// view" in general — see the doc below for why `cheersError` no longer participates in it.
///
/// **Root cause of `docs/STATE_AUDIT.md`'s Cheers finding — and why the "two `.alert` modifiers
/// conflict" hypothesis is *not* it.** That was the natural first suspect (the original code did
/// chain two boolean-driven `.alert`s on the same `Group`, one per error), and collapsing both
/// into one enum-keyed alert (this type used to have a `.cheers` case too) was the first thing
/// tried. It did not fix anything: with only one `.alert` in the tree, `cheersError`'s failure
/// still never presented, while `deleteError`'s still did — proving the count of `.alert`
/// modifiers was never the variable.
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
/// inside the `Menu`) did not break it.
///
/// A real `DispatchQueue.main.asyncAfter` delay before the alert-driving state change (~0.5s
/// reliably worked in testing; 0.25s did not) reproduced the same effect `Menu`/`confirmationDialog`
/// provide for free. That delay is not shipped: it is tuned to one machine on one day, it delays
/// the user's feedback for no reason they'd understand, and a slower device or a loaded CI runner
/// can blow past it — a wall-clock constant is what you reach for when you can't express the real
/// condition, and that is precisely the case where it hides the problem instead of solving it.
///
/// **`cheersError` is not presented via `.alert` at all any more** — see `FeedView`'s `content(_:)`
/// — it is plain inline content, matching how this app already reports every other transient error
/// (`ComposePostSheet`, `PostCommentsSheet`, `ReportContentView`, `DataExportView`). Inline content
/// has no modal-presentation step to race, which removes the failure mode this finding was about
/// instead of timing around it. `deleteError` keeps its `.alert` — its own `Menu`/
/// `confirmationDialog` already provides the transaction gap the modal needs, so it never needed
/// fixing.
private enum FeedAlert: Equatable {
    case delete(String)

    var title: String {
        switch self {
        case .delete: return "Couldn't delete that post"
        }
    }

    var message: String {
        switch self {
        case .delete(let message): return message
        }
    }
}

/// The friends-only feed. A `List` of `FeedPostCard`s with pull-to-refresh, infinite scroll, and
/// the loading/error/empty states every screen needs (master prompt §22).
struct FeedView: View {
    @Environment(\.container) private var container
    @State private var model: FeedViewModel?
    @State private var showCompose = false
    /// Mirrors `model.deleteError` via the `.onChange` in `content(_:)` rather than being read
    /// live inside the `.alert`'s own `isPresented`/`presenting` closures. See `FeedAlert`'s doc
    /// for why that live-read shape is what silently failed to present for `cheersError` (which no
    /// longer uses this at all — it's an inline message now, read straight from
    /// `model.cheersError`, no intermediate `@State`).
    @State private var presentedAlert: FeedAlert?
    /// See `AccessibilityAnnouncer`'s doc — speaks `model.cheersError` for VoiceOver, the same way
    /// `ComposePostSheet`/`PostCommentsSheet`/`ReportContentView`/`DataExportView` announce their
    /// own inline errors. `cheersError` used to get this for free from `.alert`'s own VoiceOver
    /// presentation; moving to inline text must not lose it.
    @State private var cheersAnnouncer = AccessibilityAnnouncer()

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
                // `cheersError` renders as plain inline content, not a `.alert` — see `FeedAlert`'s
                // doc for the root cause this replaces. Inline content has no separate presentation
                // step to fail: it's part of the same view-body evaluation that already reads
                // `model.cheersError` correctly on every render, so it shows up exactly when that
                // render happens, with nothing to race against and no wall-clock wait to observe it.
                .safeAreaInset(edge: .top) {
                    if let cheersError = model.cheersError {
                        Text(cheersError)
                            .font(Theme.Typography.callout)
                            .foregroundStyle(Theme.Palette.warning)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Theme.Spacing.md)
                            .background(Theme.Palette.backgroundPrimary)
                            .accessibilityIdentifier("feed-cheers-error")
                    }
                }
            }
        }
        // See `AccessibilityAnnouncer`'s doc — announces `model.cheersError` for VoiceOver on
        // genuine change only, the same convention `ComposePostSheet`/`PostCommentsSheet`/
        // `ReportContentView`/`DataExportView` use for their own inline errors.
        .onChange(of: model.cheersError) { _, new in cheersAnnouncer.announce(new) }
        // `presentedAlert` is a plain `@State` on `FeedView`, populated from `model.deleteError` by
        // the `.onChange` below rather than the `.alert` reading that `@Observable` property live
        // through a computed `Binding` — see `FeedAlert`'s doc for the elimination process this
        // came out of. `deleteError` needs no extra handling beyond that: its own
        // `Menu`/`confirmationDialog` already provides the transaction gap the alert needs.
        .onChange(of: model.deleteError) { _, newValue in
            guard let newValue else { return }
            presentedAlert = .delete(newValue)
        }
        .alert(presentedAlert?.title ?? "", isPresented: Binding(
            get: { presentedAlert != nil },
            set: { isPresented in
                guard !isPresented else { return }
                presentedAlert = nil
                model.deleteError = nil
            }
        ), presenting: presentedAlert) { _ in
            Button("OK", role: .cancel) {
                presentedAlert = nil
                model.deleteError = nil
            }
        } message: { alert in
            Text(alert.message)
        }
    }

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
        case .notAuthenticated, .forbidden, .invalidOrExpiredCode:
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
