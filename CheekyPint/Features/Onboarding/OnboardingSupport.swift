import SwiftUI

/// Brand voice + safety copy, kept in one place so the tone stays cheeky-but-responsible and
/// the responsible-drinking wording is consistent (master prompt §1, §3).
enum BrandCopy {
    static let tagline = "Your social pub diary"
    static let welcomeTitle = "Remember the good rounds"
    static let welcomeBody = "Log your pub visits, keep your favourite haunts, and hold friendly standings with your mates. One tap, and cheers."

    static let responsibleTitle = "A quick word before we start"
    static let responsibleBody = "CheekyPint is a diary, not a challenge. There are no streaks, no “drink more” nudges, and no global rankings. Please enjoy a pint responsibly and look after yourself and your mates."

    static let ageTitle = "Are you of legal drinking age?"
    static let ageBody = "You must meet the legal drinking age where you live to use CheekyPint. We default to an 18+ experience."
    static let ageConfirm = "I confirm I'm of legal drinking age where I live"
}

/// A consistent onboarding page: generous space, large confident type, one clear action area.
struct OnboardingScaffold<Content: View, Actions: View>: View {
    let systemImage: String
    let title: String
    let subtitle: String?
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions

    init(systemImage: String, title: String, subtitle: String? = nil,
         @ViewBuilder content: @escaping () -> Content = { EmptyView() },
         @ViewBuilder actions: @escaping () -> Actions) {
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
        self.content = content
        self.actions = actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Spacer(minLength: Theme.Spacing.lg)
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text(title)
                    .font(Theme.Typography.largeTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            content()
            Spacer()
            actions()
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pubBackground()
    }
}

/// Links required during onboarding (master prompt §17). These open the in-app legal documents.
struct LegalLinksView: View {
    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            Text("By continuing you agree to our")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
            HStack(spacing: Theme.Spacing.sm) {
                NavigationLink("Terms") { LegalDocumentView(document: .terms) }
                Text("·").foregroundStyle(Theme.Palette.textSecondary)
                NavigationLink("Privacy") { LegalDocumentView(document: .privacy) }
                Text("·").foregroundStyle(Theme.Palette.textSecondary)
                NavigationLink("Guidelines") { LegalDocumentView(document: .community) }
            }
            .font(Theme.Typography.caption.weight(.semibold))
            .tint(Theme.Palette.accent)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}
