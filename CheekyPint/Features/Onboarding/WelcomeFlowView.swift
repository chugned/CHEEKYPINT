import SwiftUI

/// The pre-auth onboarding flow (master prompt §17, steps 1–4):
/// brand intro → responsible-use statement → legal-age confirmation → authentication.
/// Age confirmation gates the auth controls and is never pre-checked.
struct WelcomeFlowView: View {
    @Environment(SessionController.self) private var session

    private enum Step: Hashable { case welcome, responsible, age, auth }
    @State private var path: [Step] = []

    var body: some View {
        NavigationStack(path: $path) {
            welcome
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .welcome: welcome
                    case .responsible: responsible
                    case .age: ageGate
                    case .auth: AuthView()
                    }
                }
        }
    }

    private var welcome: some View {
        OnboardingScaffold(
            systemImage: "mug.fill",
            title: BrandCopy.welcomeTitle,
            subtitle: BrandCopy.welcomeBody
        ) {
            VStack(spacing: Theme.Spacing.sm) {
                Button("Pull up a stool") { path.append(.responsible) }
                    .buttonStyle(PintButtonStyle())
                #if DEBUG
                Button("Explore in demo mode") { Task { await session.enterDemoMode() } }
                    .buttonStyle(PillButtonStyle())
                #endif
            }
        }
        .navigationBarBackButtonHidden()
    }

    private var responsible: some View {
        OnboardingScaffold(
            systemImage: "hand.raised.fill",
            title: BrandCopy.responsibleTitle,
            subtitle: BrandCopy.responsibleBody
        ) {
            Button("Makes sense") { path.append(.age) }
                .buttonStyle(PintButtonStyle())
        }
    }

    @ViewBuilder
    private var ageGate: some View {
        @Bindable var session = session
        OnboardingScaffold(
            systemImage: "checkmark.seal.fill",
            title: BrandCopy.ageTitle,
            subtitle: BrandCopy.ageBody
        ) {
            Toggle(BrandCopy.ageConfirm, isOn: $session.pendingAgeConfirmed)
                .tint(Theme.Palette.accent)
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.textPrimary)
                .accessibilityIdentifier("ageConfirmationToggle")
                .coasterCard()
        } actions: {
            VStack(spacing: Theme.Spacing.md) {
                Button("Continue") { path.append(.auth) }
                    .buttonStyle(PintButtonStyle())
                    .disabled(!session.pendingAgeConfirmed)
                    .opacity(session.pendingAgeConfirmed ? 1 : 0.5)
                LegalLinksView()
            }
        }
    }
}
