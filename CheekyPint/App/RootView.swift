import SwiftUI

/// Chooses the top-level flow from the current session phase.
struct RootView: View {
    @Environment(SessionController.self) private var session

    var body: some View {
        Group {
            switch session.phase {
            case .loading:
                LaunchView()
            case .signedOut:
                WelcomeFlowView()
            case .onboarding:
                ProfileSetupFlowView()
            case .ready:
                MainTabView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isReady)
    }

    private var isReady: Bool {
        if case .ready = session.phase { return true }
        return false
    }
}

/// The launch/splash — a premium coaster with the wordmark while we resolve the session.
struct LaunchView: View {
    var body: some View {
        ZStack {
            Theme.Palette.backgroundPrimary.ignoresSafeArea()
            VStack(spacing: Theme.Spacing.md) {
                PintGlassMark(size: 72)
                Text("CheekyPint")
                    .font(Theme.Typography.wordmark)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("CheekyPint")
    }
}

/// The brand mark: a simple cream pint-glass silhouette with one cheeky asymmetric foam
/// detail and a restrained amber fill (matches the app-icon brief in docs).
struct PintGlassMark: View {
    var size: CGFloat = 44
    var body: some View {
        ZStack {
            Image(systemName: "mug.fill")
                .font(.system(size: size))
                .foregroundStyle(Theme.Palette.beer) // gold beer
            Image(systemName: "mug")
                .font(.system(size: size))
                .foregroundStyle(Theme.Palette.accent) // green rim
        }
        .accessibilityHidden(true)
    }
}
