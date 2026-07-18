import SwiftUI

/// The primary, confident action button — a solid green pill with white text and a soft coloured
/// shadow. Tactile press honours Reduce Motion (master prompt §5, §21).
struct PintButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.headline.weight(.bold))
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Theme.Palette.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
            .foregroundStyle(.white)
            .shadow(color: Theme.Palette.accent.opacity(0.35), radius: 14, y: 6)
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.97 : 1))
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

/// A pure press-scale style (no chrome), used by the big circular "Log a pint" button which
/// supplies its own background.
struct ScaleButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.94 : 1))
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// A restrained secondary button (outlined, cream text).
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.headline)
            .frame(maxWidth: .infinity, minHeight: Theme.minTapTarget)
            .padding(.horizontal, Theme.Spacing.md)
            .foregroundStyle(Theme.Palette.textPrimary)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .stroke(Theme.Palette.textSecondary.opacity(0.35), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A small amber-tinted pill (used for the QR shortcut, chips, etc.).
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.callout)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xs)
            .frame(minHeight: Theme.minTapTarget)
            .background(Theme.Palette.accent.opacity(0.16), in: Capsule())
            .foregroundStyle(Theme.Palette.accent)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A neutral welfare banner shown instead of celebration after clustered entries (§3.7).
struct WelfareBanner: View {
    let message: String
    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "drop.fill")
                .foregroundStyle(Theme.Palette.accent)
                .accessibilityHidden(true)
            Text(message)
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Palette.textPrimary)
            Spacer(minLength: 0)
        }
        .coasterCard()
        .accessibilityElement(children: .combine)
    }
}

/// A generic empty/error placeholder used across screens (loading/empty/offline/error states).
struct StatusView: View {
    let systemImage: String
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(Theme.Palette.textSecondary)
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.Palette.textPrimary)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(SecondaryButtonStyle())
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Spacing.xl)
    }
}
