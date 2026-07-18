import SwiftUI

/// In-app legal / safety documents (master prompt §17, §18, §29). Shows concise in-app copy and
/// links to the full, canonical documents. The full templates live in docs/legal and must be
/// reviewed by a qualified professional before launch.
enum LegalDocument: Hashable {
    case privacy, terms, community, responsibleDrinking, openSource

    var title: String {
        switch self {
        case .privacy: return "Privacy Policy"
        case .terms: return "Terms of Use"
        case .community: return "Community Guidelines"
        case .responsibleDrinking: return "Drink Responsibly"
        case .openSource: return "Open-source Notices"
        }
    }

    var url: URL? {
        switch self {
        case .privacy: return URL(string: "https://cheekypint.app/privacy")
        case .terms: return URL(string: "https://cheekypint.app/terms")
        case .community: return URL(string: "https://cheekypint.app/guidelines")
        case .responsibleDrinking: return URL(string: "https://cheekypint.app/responsible")
        case .openSource: return nil
        }
    }

    var body: String {
        switch self {
        case .responsibleDrinking:
            return """
            CheekyPint is a diary and pub memory app — not a drinking game.

            • Know your limits and pace yourself.
            • Alternate with water and never drink on an empty stomach.
            • Never drink and drive.
            • If drinking stops being fun, it's okay to stop.

            If you're worried about your drinking, please speak to a GP or a local support \
            service. CheekyPint doesn't provide medical advice.
            """
        case .community:
            return """
            Keep CheekyPint friendly:

            • Be respectful. No harassment, hate, or impersonation.
            • Keep profile photos and text appropriate.
            • Don't encourage dangerous or excessive drinking.

            You can block or report anyone. Repeat offenders may be removed.
            """
        case .privacy:
            return """
            We collect only what the app needs: your account, the drinks and pubs you log, \
            your friends, and basic product analytics. We never sell your data or run ads.

            You control who sees what, and you can export or delete your data at any time from \
            Settings. Broad city is optional and off to friends by default; we never store your \
            street address or track your location in the background.

            This is an in-app summary — see the full policy for details and your GDPR rights.
            """
        case .terms:
            return """
            CheekyPint is provided for personal, non-commercial use by adults of legal drinking \
            age. You're responsible for what you log and share. We may suspend accounts that \
            break the Community Guidelines.

            This is an in-app summary — see the full Terms for the complete agreement.
            """
        case .openSource:
            return """
            CheekyPint is built with Apple's frameworks (SwiftUI, MapKit, VisionKit, CryptoKit) \
            and Supabase for its backend. See THIRD_PARTY_NOTICES.md in the project for details.
            """
        }
    }
}

struct LegalDocumentView: View {
    let document: LegalDocument

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text(document.body)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                if let url = document.url {
                    Link("Read the full document", destination: url)
                        .font(Theme.Typography.callout.weight(.semibold))
                        .tint(Theme.Palette.accent)
                }
            }
            .padding(Theme.Spacing.lg)
        }
        .pubBackground()
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
