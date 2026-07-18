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
                .task { await session.bootstrap() }
                .onOpenURL { url in
                    Task { await handle(url) }
                }
        }
    }

    /// Route auth callbacks vs friend/session deep links.
    @MainActor
    private func handle(_ url: URL) async {
        if url.host == "auth-callback" || url.path.contains("auth-callback") {
            if (try? await container.auth.handleCallbackURL(url)) != nil {
                await session.didAuthenticate()
            }
        } else {
            session.handleDeepLink(url)
        }
    }
}
