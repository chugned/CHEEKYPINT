import SwiftUI
import CheekyPintCore

/// The friends-only feed. A `List` of `FeedPostCard`s with pull-to-refresh, infinite scroll, and
/// the loading/error/empty states every screen needs (master prompt §22).
struct FeedView: View {
    @Environment(\.container) private var container
    @State private var model: FeedViewModel?
    @State private var showCompose = false

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
                StatusView(systemImage: "wifi.slash", title: "Couldn't load the feed",
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
                            onCommentCountChanged: { model.updateCommentCount(postID: post.id, count: $0) }
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
        .alert("Couldn't update Cheers", isPresented: Binding(
            get: { model.cheersError != nil },
            set: { if !$0 { model.cheersError = nil } }
        )) {
            Button("OK", role: .cancel) { model.cheersError = nil }
        } message: {
            Text(model.cheersError ?? "Please try again.")
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
