import SwiftUI
import CheekyPintCore

/// Reusable privacy toggles, shared by onboarding and Settings (master prompt §9, §18). Each
/// switch maps to a `Visibility` (on = friends, off = private). Totals are grouped into one
/// switch here; the full Settings screen can expose them individually.
struct PrivacyChoicesView: View {
    @Binding var privacy: PrivacySettings
    var showIndividualTotals = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Label("Who sees what", systemImage: "lock.shield")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("Only accepted friends can ever see your details. You're in charge.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)

                group {
                    row("Profile visible to friends", \.profileVisibility)
                    row("Profile photo", \.avatarVisibility)
                    row("Show my city", \.cityVisibility)
                }
                group {
                    if showIndividualTotals {
                        row("Session total", \.sessionTotalVisibility)
                        row("Weekly total", \.weeklyTotalVisibility)
                        row("Monthly total", \.monthlyTotalVisibility)
                        row("Yearly total", \.yearlyTotalVisibility)
                    } else {
                        Toggle("Show my totals to friends", isOn: allTotalsBinding)
                            .tint(Theme.Palette.accent)
                    }
                }
                group {
                    row("Favourite pubs", \.favouritePubsVisibility)
                    row("Recent shared sessions", \.sharedSessionsVisibility)
                }
            }
            .font(Theme.Typography.callout)
            .foregroundStyle(Theme.Palette.textPrimary)
            .padding(.vertical, Theme.Spacing.sm)
        }
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: Theme.Spacing.sm) { content() }.coasterCard()
    }

    private func row(_ title: String, _ keyPath: WritableKeyPath<PrivacySettings, CheekyPintCore.Visibility>) -> some View {
        Toggle(title, isOn: binding(keyPath)).tint(Theme.Palette.accent)
    }

    private func binding(_ keyPath: WritableKeyPath<PrivacySettings, CheekyPintCore.Visibility>) -> Binding<Bool> {
        Binding(
            get: { privacy[keyPath: keyPath] == .friends },
            set: { privacy[keyPath: keyPath] = $0 ? .friends : .private }
        )
    }

    private var allTotalsBinding: Binding<Bool> {
        Binding(
            get: { privacy.weeklyTotalVisibility == .friends },
            set: { on in
                let value: CheekyPintCore.Visibility = on ? .friends : .private
                privacy.sessionTotalVisibility = value
                privacy.weeklyTotalVisibility = value
                privacy.monthlyTotalVisibility = value
                privacy.yearlyTotalVisibility = value
            }
        )
    }
}
