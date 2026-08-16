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

    /// Scrollable, but only when it has to be.
    ///
    /// The layout was a plain `VStack` with a trailing `Spacer`, which pins the actions to the
    /// bottom and silently clips whatever doesn't fit above them. That is fine at default text
    /// sizes for a title and one button, and not fine at accessibility XXL for the sign-in steps,
    /// where a large title, a subtitle carrying the user's own email address, a field, a primary
    /// button, an error line, a resend row and the three legal links all have to coexist.
    ///
    /// The content keeps a *minimum* height of one screenful — `minHeight`, deliberately, not
    /// `containerRelativeFrame`, which sets an exact height and would go on clipping — so the
    /// `Spacer` still pushes the actions to the bottom exactly as before when there is room, and
    /// past that the `ScrollView` takes over instead of the overflow being cut off.
    /// `.scrollBounceBehavior(.basedOnSize)` keeps the short screens feeling static rather than
    /// rubber-banding on a screen with nothing to scroll.
    var body: some View {
        GeometryReader { proxy in
            ScrollView {
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
                    Spacer(minLength: Theme.Spacing.lg)
                    actions()
                }
                .padding(Theme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: proxy.size.height, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
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
