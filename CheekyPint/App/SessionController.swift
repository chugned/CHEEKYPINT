import SwiftUI
import CheekyPintCore

/// Drives which top-level flow is shown and holds the signed-in user's profile. Owns the
/// coarse app phases; feature view models own their own screen state.
@MainActor
@Observable
final class SessionController {
    enum Phase: Equatable {
        case loading
        case signedOut
        case onboarding(Profile)   // authenticated but hasn't finished setup / age confirmation
        case ready(Profile)
    }

    let container: AppContainer
    private(set) var phase: Phase = .loading
    private let surnameKey = "CheekyPint.friendCircleSurname"

    /// Age confirmation is collected pre-auth (§17). We hold it here until we have a user to
    /// persist it against, immediately after sign-in.
    var pendingAgeConfirmed = false

    /// A friend/session deep link captured before we were ready to present it.
    var pendingDeepLink: DeepLink?

    init(container: AppContainer) {
        self.container = container
    }

    func bootstrap() async {
        if let surname = UserDefaults.standard.string(forKey: surnameKey), !surname.isEmpty {
            await DemoWorld.shared.activate(surname: surname)
            phase = .ready(await DemoWorld.shared.currentProfile)
            return
        }
        phase = .signedOut
    }

    /// Reload the profile and decide whether onboarding is complete. The gate is a recorded
    /// legal-age confirmation (master prompt §34).
    func refreshProfile() async {
        do {
            let profile = try await container.profiles.fetchMyProfile()
            phase = profile.hasConfirmedLegalAge ? .ready(profile) : .onboarding(profile)
        } catch SupabaseError.notAuthenticated {
            phase = .signedOut
        } catch {
            // Keep the user signed in but show onboarding if we can't yet read a profile.
            phase = .signedOut
        }
    }

    func didAuthenticate() async {
        // Persist the pre-auth age confirmation as soon as we have a session.
        if pendingAgeConfirmed {
            try? await container.profiles.confirmLegalAge()
        }
        await refreshProfile()
    }

    func completeOnboarding() async {
        container.analytics.track(.onboardingCompleted)
        await refreshProfile()
    }

    func signOut() async {
        await DemoWorld.shared.deactivate()
        await container.auth.signOut()
        UserDefaults.standard.removeObject(forKey: surnameKey)
        pendingAgeConfirmed = false
        phase = .signedOut
    }

    /// Friend-circle mode: no third-party auth, just a locally persisted surname and the
    /// in-memory backend that powers the rest of the app.
    func enterFriendCircleMode(surname: String) async {
        let clean = surname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        pendingAgeConfirmed = true
        UserDefaults.standard.set(clean, forKey: surnameKey)
        await DemoWorld.shared.activate(surname: clean)
        phase = .ready(await DemoWorld.shared.currentProfile)
    }

    /// DEBUG-only: skip auth entirely and explore the app with seeded, in-memory data.
    func enterDemoMode() async {
        await DemoWorld.shared.activate(surname: "Alice")
        phase = .ready(await DemoWorld.shared.currentProfile)
    }

    var currentProfile: Profile? {
        switch phase {
        case let .onboarding(profile), let .ready(profile): return profile
        default: return nil
        }
    }

    // MARK: Deep links

    func handleDeepLink(_ url: URL) {
        guard let link = container.deepLinkParser.parse(url) else { return }
        pendingDeepLink = link
    }

    func consumeDeepLink() -> DeepLink? {
        defer { pendingDeepLink = nil }
        return pendingDeepLink
    }
}
