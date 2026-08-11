import SwiftUI

/// In-app account deletion (master prompt §18). Explains what happens, asks for explicit
/// confirmation, tears down the data, and signs out. No emailing support required.
struct DeleteAccountView: View {
    @Environment(SessionController.self) private var session
    @Environment(\.container) private var container
    @State private var confirmText = ""
    @State private var isDeleting = false
    @State private var errorMessage: String?

    private let phrase = "DELETE"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Label("This can't be undone", systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Typography.title).foregroundStyle(Theme.Palette.warning)
                Text("""
                Deleting your account will:
                • remove your profile, photo, and username
                • delete your pint diary and pub visits
                • remove you from friends' lists and standings
                • revoke your friend codes and sessions

                Your data is deleted or anonymised per our Data Retention Policy.
                """)
                .font(Theme.Typography.body).foregroundStyle(Theme.Palette.textSecondary)

                Text("Type \(phrase) to confirm").font(Theme.Typography.callout).foregroundStyle(Theme.Palette.textPrimary)
                TextField(phrase, text: $confirmText)
                    .textFieldStyle(.roundedBorder).textInputAutocapitalization(.characters).autocorrectionDisabled()

                if let errorMessage { Text(errorMessage).foregroundStyle(Theme.Palette.warning) }

                Button("Delete my account", role: .destructive) { Task { await delete() } }
                    .buttonStyle(PintButtonStyle())
                    .disabled(confirmText != phrase || isDeleting)
                    .opacity(confirmText == phrase ? 1 : 0.5)
            }
            .padding(Theme.Spacing.lg)
        }
        .pubBackground()
        .navigationTitle("Delete account")
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if isDeleting { ProgressView().tint(Theme.Palette.accent) } }
    }

    private func delete() async {
        isDeleting = true; errorMessage = nil
        defer { isDeleting = false }
        do {
            // Calls the delete-account Edge Function, which runs delete_account() as the caller
            // (anonymise + tear down app data), then removes their avatar/post-photo storage
            // objects and deletes the auth user — all before this call returns. If it fails
            // partway (e.g. after anonymising but before the auth-user delete), it throws and
            // the catch below reports it; nothing here treats a partial run as success.
            try await container.profiles.deleteAccount()
            await session.signOut()
        } catch let error as SupabaseError {
            errorMessage = error.friendlyMessage
        } catch {
            errorMessage = "Couldn't delete your account. Please try again."
        }
    }
}
