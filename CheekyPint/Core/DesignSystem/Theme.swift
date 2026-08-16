import SwiftUI

/// The CheekyPint design-token system (master prompt §5). Everything visual references these
/// tokens rather than hard-coded values, so the "premium digital pub coaster" look stays
/// consistent and Dark Mode (primary) / Light Mode (alternative) both work from one source.
enum Theme {
    /// Semantic colours, backed by the asset catalog (each has a light + dark variant).
    /// Fresh green + white direction: `accent` (green) drives actions/highlights, while `beer`
    /// (warm gold) is reserved for actual beer glyphs so a pint still looks like a pint.
    enum Palette {
        static let backgroundPrimary = Color("BackgroundPrimary")
        static let backgroundSecondary = Color("BackgroundSecondary")
        static let textPrimary = Color("TextPrimary")
        static let textSecondary = Color("TextSecondary")
        static let accent = Color("AccentGreen")
        static let beer = Color("AccentAmber")
        static let warning = Color("Warning")
        static let success = Color("Success")
        /// Brand-only forest greens. Deeper and more organic than `accent`, they are reserved
        /// for the logo lockup so the wordmark reads as the brand rather than as an action.
        static let forest = Color("ForestGreen")
        static let forestDeep = Color("ForestGreenDeep")
        /// Fixed (non-adaptive) colours for `PhotoViewerView`'s full-bleed backdrop and its
        /// overlaid controls (close button, "Photo unavailable" placeholder). Deliberately not
        /// asset-catalog light/dark colours: every full-screen photo viewer convention
        /// (Photos.app, and every major social feed) stages the photo against a neutral black
        /// regardless of the app's own Light/Dark Mode, so the photo's own colours read
        /// correctly against it either way.
        static let photoViewerBackground = Color.black
        static let photoViewerControl = Color.white
    }

    /// Brand gradients.
    enum Gradients {
        /// The wordmark runs moss → deep pine so the Lobster script has depth instead of a
        /// flat fill. Both stops are asset colours, so Dark Mode inverts the ramp for legibility.
        static let wordmark = LinearGradient(
            colors: [Palette.forest, Palette.forestDeep],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// 4-pt based spacing scale.
    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }

    /// Fixed heights for image tiles whose height is independent of the source photo's aspect
    /// ratio (see `FeedPostCard.photoHeight`'s doc for why fixing the height matters). One place
    /// for these instead of a local magic number at each call site.
    enum Sizing {
        /// The composer's picked-photo thumbnail (`ComposePostSheet`).
        static let photoPreview: CGFloat = 160
    }

    /// Corner-radius scale — rounded but not bubbly.
    enum Radius {
        static let sm: CGFloat = 10
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let pill: CGFloat = 999
    }

    /// Typography scale. Rounded SF for warmth; text styles so Dynamic Type scales everything.
    enum Typography {
        /// The Lobster script the logo is set in (bundled via `UIAppFonts`). `relativeTo:` keeps
        /// the custom face on the Dynamic Type ramp; if registration ever fails, SwiftUI falls
        /// back to the system face at the same size rather than dropping the wordmark.
        private static let brandFace = "Lobster-Regular"
        /// In-app wordmark (nav headers) — sits on the `.title2` ramp like the rest of the UI.
        static let wordmark = Font.custom(brandFace, size: 34, relativeTo: .title2)
        /// The splash lockup, where the logo is the only thing on screen and can breathe.
        static let wordmarkLarge = Font.custom(brandFace, size: 58, relativeTo: .largeTitle)
        static let largeTitle = Font.system(.largeTitle, design: .rounded).weight(.bold)
        static let title = Font.system(.title2, design: .rounded).weight(.bold)
        static let headline = Font.system(.headline, design: .rounded)
        static let body = Font.system(.body, design: .rounded)
        static let callout = Font.system(.callout, design: .rounded)
        static let caption = Font.system(.caption, design: .rounded).weight(.medium)
        /// The prominent session count / totals.
        static let count = Font.system(.largeTitle, design: .rounded).weight(.heavy)
    }

    /// Standard minimum tappable dimension (Apple HIG / §5).
    static let minTapTarget: CGFloat = 44
}

extension View {
    /// The recurring card surface: white (secondary) background, generous radius, and a soft
    /// shadow for the clean, modern, lifted look.
    func coasterCard(padding: CGFloat = Theme.Spacing.md) -> some View {
        self
            .padding(padding)
            .background(Theme.Palette.backgroundSecondary, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            .shadow(color: Color.black.opacity(0.06), radius: 10, y: 4)
    }

    /// Fill the screen with the primary background, ignoring safe-area, behind content.
    func pubBackground() -> some View {
        background(Theme.Palette.backgroundPrimary.ignoresSafeArea())
    }
}
