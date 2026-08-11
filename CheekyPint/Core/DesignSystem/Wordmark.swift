import SwiftUI

/// The CheekyPint logo lockup.
///
/// The logo is custom lettering, not type: the `C`'s tail sweeps under the whole word and lifts
/// again past the `t`, so it cannot be reproduced by setting a typeface. It ships as artwork in
/// `Wordmark.imageset`, stored as a pure alpha mask with a template rendering intent — that way
/// one asset takes the theme's forest gradient and inverts for Dark Mode automatically, rather
/// than needing a separate light and dark copy.
struct Wordmark: View {
    enum Scale {
        /// In-app header, on the `.title2` Dynamic Type ramp.
        case header
        /// The launch lockup, where the logo is the only thing on screen.
        case splash
    }

    var scale: Scale = .header

    /// Width, not point size — the artwork is a fixed-aspect image. `@ScaledMetric` keeps it on
    /// the Dynamic Type ramp so the logo still grows with the user's text size.
    @ScaledMetric(relativeTo: .title2) private var headerWidth: CGFloat = 150
    @ScaledMetric(relativeTo: .largeTitle) private var splashWidth: CGFloat = 260

    /// Trimmed ink bounds of the source artwork (1428 x 478).
    private static let aspectRatio: CGFloat = 2.98745

    private var width: CGFloat {
        switch scale {
        case .header: headerWidth
        case .splash: splashWidth
        }
    }

    var body: some View {
        Image("Wordmark")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: width, height: width / Self.aspectRatio)
            .foregroundStyle(Theme.Gradients.wordmark)
            .accessibilityLabel("CheekyPint")
    }
}

#Preview("Wordmark") {
    VStack(spacing: Theme.Spacing.xl) {
        Wordmark(scale: .splash)
        Wordmark(scale: .header)
    }
    .padding(Theme.Spacing.xl)
    .pubBackground()
}
