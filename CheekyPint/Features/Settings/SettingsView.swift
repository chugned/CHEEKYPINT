import SwiftUI

/// Settings (master prompt §18). Account deletion is initiated in-app; a permanent "Drink
/// responsibly" link lives under Safety.
struct SettingsView: View {
    @Environment(SessionController.self) private var session
    @Environment(\.container) private var container
    @State private var showSignOutConfirm = false

    var body: some View {
        List {
            Section("Account") {
                NavigationLink { EditProfileView() } label: { Label("Edit profile", systemImage: "person.text.rectangle") }
                Button { showSignOutConfirm = true } label: { Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right") }
                NavigationLink { DeleteAccountView() } label: {
                    Label("Delete account", systemImage: "trash").foregroundStyle(Theme.Palette.warning)
                }
            }
            Section("Privacy") {
                NavigationLink { PrivacySettingsView() } label: { Label("Privacy settings", systemImage: "lock.shield") }
                NavigationLink { BlockedUsersView() } label: { Label("Blocked users", systemImage: "hand.raised") }
            }
            Section("Safety") {
                NavigationLink { LegalDocumentView(document: .responsibleDrinking) } label: {
                    Label("Drink responsibly", systemImage: "heart")
                }
                NavigationLink { LegalDocumentView(document: .community) } label: {
                    Label("Community guidelines", systemImage: "person.2")
                }
                Link(destination: URL(string: "mailto:support@cheekypint.app")!) {
                    Label("Report a problem / Support", systemImage: "envelope")
                }
            }
            Section("Legal") {
                NavigationLink { LegalDocumentView(document: .privacy) } label: { Label("Privacy Policy", systemImage: "doc.text") }
                NavigationLink { LegalDocumentView(document: .terms) } label: { Label("Terms of Use", systemImage: "doc.text") }
                NavigationLink { LegalDocumentView(document: .openSource) } label: { Label("Open-source notices", systemImage: "chevron.left.forwardslash.chevron.right") }
                LabeledContent("Version", value: appVersion)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.backgroundPrimary)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Sign out of CheekyPint?", isPresented: $showSignOutConfirm, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { Task { await session.signOut() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(v) (\(b))"
    }
}
