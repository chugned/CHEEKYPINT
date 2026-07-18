import SwiftUI
import CheekyPintCore

/// Full privacy controls with per-period totals (master prompt §18). Includes a switch to hide
/// all quantities from friends while keeping the private diary (§3.10).
struct PrivacySettingsView: View {
    @Environment(\.container) private var container
    @State private var privacy: PrivacySettings?
    @State private var isSaving = false
    @State private var savedTick = false

    var body: some View {
        Group {
            if let binding = privacyBinding {
                VStack(spacing: 0) {
                    PrivacyChoicesView(privacy: binding, showIndividualTotals: true)
                    Button(savedTick ? "Saved ✓" : "Save changes") { Task { await save() } }
                        .buttonStyle(PintButtonStyle())
                        .disabled(isSaving)
                        .padding(Theme.Spacing.lg)
                }
            } else {
                ProgressView().tint(Theme.Palette.accent)
            }
        }
        .pubBackground()
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .task { if privacy == nil { privacy = try? await container.profiles.fetchMyPrivacy() } }
    }

    private var privacyBinding: Binding<PrivacySettings>? {
        guard privacy != nil else { return nil }
        return Binding(get: { privacy! }, set: { privacy = $0; savedTick = false })
    }

    private func save() async {
        guard let privacy else { return }
        isSaving = true; defer { isSaving = false }
        do { try await container.profiles.updatePrivacy(privacy.asUpdate()); savedTick = true }
        catch { savedTick = false }
    }
}
