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

    /// Age confirmation is collected pre-auth (§17), so it has no user to be stored against when
    /// it is given. It is written at the *end* of profile setup, in the same PATCH as the display
    /// name — not the instant a session appears — because `legal_age_confirmed_at` is also the
    /// `.onboarding` → `.ready` gate below. Recording it at sign-in would mark a brand-new user as
    /// set up before they had entered a name, and hand them straight to `MainTabView` with the
    /// local part of their email address for a display name.
    var pendingAgeConfirmed = false

    init(container: AppContainer) {
        self.container = container
    }

    /// Launch-time work, called once from `CheekyPintApp`'s root `.task`.
    ///
    /// The sweep comes first, before any early return below, because it must happen on every
    /// launch regardless of which phase the app resolves to — including the `-uiTestDemo` path,
    /// and including a launch that ends signed out.
    ///
    /// The phase decision, in order: demo mode if the UI-test argument asked for it; otherwise
    /// signed out unless the Keychain holds a session; otherwise that session is proven usable
    /// (refreshing it if the access token has expired) and the caller's own `profiles` row is
    /// read, whose `legal_age_confirmed_at` decides `.onboarding` (set-up unfinished) from
    /// `.ready`.
    func bootstrap() async {
        sweepStaleTemporaryExports()
        #if DEBUG
        // Deterministic entry for UI-test screenshots: boot straight into demo mode.
        if ProcessInfo.processInfo.arguments.contains("-uiTestDemo") {
            await enterDemoMode()
            return
        }
        #endif
        guard await container.auth.hasSession else {
            // No keychain session: nothing to restore. `deactivate()` rather than "leave it
            // alone" because a launch that ends signed out must not inherit a demo world from
            // whatever ran before it in this process.
            await DemoWorld.shared.deactivate()
            phase = .signedOut
            return
        }
        do {
            // Proves the stored session is still usable before the app commits to a signed-in
            // phase: `validAccessToken()` refreshes when the access token has expired, which it
            // will have on any launch more than an hour after the last one, and throws if GoTrue
            // has since rejected the refresh token.
            _ = try await container.auth.validAccessToken()
        } catch {
            // A refresh token GoTrue no longer accepts is dead — keeping it would make every
            // subsequent request fail the same way. Clear it and start clean.
            await signOut()
            return
        }
        await adoptRealSession()
    }

    /// The single funnel for "a real Supabase session is now in force". Every path that ends with
    /// one goes through here — a fresh code sign-in and a cold launch that restored the keychain
    /// alike — because the invariant it enforces is what makes the rest of the app talk to the
    /// backend at all.
    ///
    /// `DemoWorld.shared.isActive` is checked at the top of every repository method; while it is
    /// true, *no* call reaches Supabase, and two phones stay two isolated local worlds no matter
    /// how correct the server is. So a real session and an active demo world must never coexist,
    /// and the deactivation happens here, before the first profile read, rather than being left to
    /// each caller to remember.
    private func adoptRealSession() async {
        await DemoWorld.shared.deactivate()
        await refreshProfile()
    }

    /// Deletes anything left in `DataExportView.exportDirectory` from a previous run.
    ///
    /// `DataExportView` already bounds the file on both ends within a session — it sweeps before
    /// each new export and again on `.onDisappear` — but neither runs if the process dies while
    /// that screen is open: a force-quit or an OOM kill fires no `.onDisappear`, and iOS's `tmp`
    /// reclamation is opportunistic, not scheduled. Without this call there is no code path left
    /// that will ever remove the file, and the file is a complete personal-data dump: profile,
    /// pint diary (health-adjacent under this project's own reading), posts and comments, friends,
    /// blocks placed, reports filed. An unbounded retention window for that is not defensible
    /// under DSGVO Art. 5(1)(e) storage limitation, which the app must satisfy under Austrian DSG.
    ///
    /// Deliberately unconditional and ignoring its own result: `clearExportDirectory()` is
    /// idempotent and a missing directory is the normal case (see
    /// `DataExportTests.testClearExportDirectoryIsIdempotentAcrossRepeatedCalls`, which covers
    /// exactly this nothing-to-clear path). Housekeeping must never be able to fail a launch.
    private func sweepStaleTemporaryExports() {
        DataExportView.clearExportDirectory()
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
            // Any other failure (offline, a 5xx) also lands on the welcome flow, because there is
            // no phase for "signed in, profile unread" and inventing one is a bigger change than
            // this. The Keychain session is deliberately left intact, so this is recoverable:
            // signing in again with the same address restores the same account rather than
            // stranding it.
            phase = .signedOut
        }
    }

    // MARK: Email one-time-code sign-in

    /// Step 1: ask GoTrue to email a six-digit code, creating the user if this address is new
    /// (`auth_bootstrap`'s `on_auth_user_created` trigger gives them a `profiles` and a
    /// `privacy_settings` row in the same transaction, so a brand-new user always has both).
    func sendSignInCode(to email: String) async throws {
        try await container.auth.sendEmailOTP(email: email)
    }

    /// Step 2: exchange the code for a session, then adopt it.
    func signIn(email: String, code: String) async throws {
        _ = try await container.auth.verifyEmailOTP(email: email, token: code)
        await adoptRealSession()
    }

    func didAuthenticate() async {
        await adoptRealSession()
    }

    func completeOnboarding() async {
        container.analytics.track(.onboardingCompleted)
        await refreshProfile()
    }

    func signOut() async {
        await DemoWorld.shared.deactivate()
        await container.auth.signOut()
        // A private post photo (post-images bucket) must not survive the session that could see
        // it — see ImageLoader.clear()'s doc. Sign-out is the common exit from any authenticated
        // session, so this is the primary place that guarantee is enforced.
        await ImageLoader.shared.clear()
        pendingAgeConfirmed = false
        phase = .signedOut
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

}
