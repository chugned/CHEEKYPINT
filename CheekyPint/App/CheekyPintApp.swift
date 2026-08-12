import SwiftUI

@main
struct CheekyPintApp: App {
    private let container: AppContainer
    @State private var session: SessionController

    init() {
        let container = AppContainer(analytics: NoOpAnalytics())
        self.container = container
        _session = State(initialValue: SessionController(container: container))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(\.container, container)
                .tint(Theme.Palette.accent)
                .task {
                    await wireImageLoader()
                    await session.bootstrap()
                }
                .onOpenURL { url in
                    Task { await handle(url) }
                }
        }
    }

    /// Post photos live in a private bucket whose read policy is evaluated per request, so every
    /// fetch needs the caller's access token. Wire it into the shared `ImageLoader` once here,
    /// before `bootstrap()` can put the app into a state where a feed renders, rather than
    /// threading the provider through every view that shows a post photo.
    private func wireImageLoader() async {
        await ImageLoader.shared.setTokenProvider { [auth = container.auth] in
            try? await auth.validAccessToken()
        }
        // The only host the bearer token may ever be sent to (see ImageLoader.allowedTokenHost).
        await ImageLoader.shared.setAllowedHost(container.config.storageURL.host)
    }

    /// The custom URL scheme remains only for authentication callbacks.
    @MainActor
    private func handle(_ url: URL) async {
        if url.host == "auth-callback" || url.path.contains("auth-callback") {
            if (try? await container.auth.handleCallbackURL(url)) != nil {
                await session.didAuthenticate()
            }
        }
    }
}
