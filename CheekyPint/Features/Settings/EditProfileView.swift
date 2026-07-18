import SwiftUI
import CheekyPintCore

/// Edit profile + change username / broad location (master prompt §18). Username is validated
/// with the tested `UsernameValidator`; text is sanitised before saving.
struct EditProfileView: View {
    @Environment(SessionController.self) private var session
    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var username = ""
    @State private var bio = ""
    @State private var city = ""
    @State private var usernameError: String?
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let validator = UsernameValidator()
    private let sanitizer = ProfileTextSanitizer()

    var body: some View {
        Form {
            Section("Name") {
                TextField("Display name", text: $displayName)
            }
            Section("Username") {
                TextField("username", text: $username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onChange(of: username) { _, value in validateUsername(value) }
                if let usernameError { Text(usernameError).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.warning) }
            }
            Section("About") {
                TextField("Short bio", text: $bio, axis: .vertical).lineLimit(2...4)
            }
            Section {
                TextField("e.g. Graz, Austria", text: $city)
            } header: {
                Text("Broad location")
            } footer: {
                Text("A broad area only — never your address. Off to friends by default.")
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(Theme.Palette.warning) }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.backgroundPrimary)
        .navigationTitle("Edit profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }.disabled(isSaving || usernameError != nil)
            }
        }
        .onAppear(perform: populate)
    }

    private func populate() {
        guard let profile = session.currentProfile else { return }
        displayName = profile.displayName
        username = profile.username ?? ""
        bio = profile.bio ?? ""
        city = profile.city ?? ""
    }

    private func validateUsername(_ value: String) {
        guard !value.isEmpty else { usernameError = nil; return }
        switch validator.validate(value) {
        case .success: usernameError = nil
        case .failure(let error): usernameError = message(for: error)
        }
    }

    private func message(for error: UsernameValidationError) -> String {
        switch error {
        case .empty: return "Enter a username."
        case .tooShort(let min): return "At least \(min) characters."
        case .tooLong(let max): return "At most \(max) characters."
        case .invalidCharacters: return "Use letters, numbers, and underscores only."
        case .mustStartWithLetter: return "Start with a letter."
        case .reserved: return "That username isn't available."
        }
    }

    private func save() async {
        isSaving = true; errorMessage = nil
        defer { isSaving = false }
        var update = ProfileUpdate(
            displayName: sanitizer.sanitizeDisplayName(displayName),
            bio: sanitizer.sanitizeBio(bio),
            city: sanitizer.sanitizeCity(city)
        )
        if !username.isEmpty, case let .success(normalised) = validator.validate(username) {
            update.username = normalised
        }
        do {
            try await container.profiles.updateProfile(update)
            await session.refreshProfile()
            dismiss()
        } catch let error as SupabaseError {
            errorMessage = error == .forbidden ? "That username is taken." : error.friendlyMessage
        } catch {
            errorMessage = "Couldn't save. Please try again."
        }
    }
}
