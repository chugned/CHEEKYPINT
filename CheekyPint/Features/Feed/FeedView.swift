import SwiftUI
import CheekyPintCore

/// The friends-only feed. A `List` of `FeedPostCard`s with pull-to-refresh, infinite scroll, and
/// the loading/error/empty states every screen needs (master prompt §22).
struct FeedView: View {
    @Environment(\.container) private var container
    @State private var model: FeedViewModel?

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
            }
        }
        .task {
            if model == nil {
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
                            onToggleCheers: { Task { await model.toggleCheers(post) } }
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
}
