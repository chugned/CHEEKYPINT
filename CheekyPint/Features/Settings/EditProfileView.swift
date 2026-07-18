import SwiftUI
import PhotosUI
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
    @State private var pickedItem: PhotosPickerItem?
    @State private var avatarData: Data?
    @State private var usernameError: String?
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let validator = UsernameValidator()
    private let sanitizer = ProfileTextSanitizer()

    var body: some View {
        Form {
            Section("Profile picture") {
                HStack {
                    Spacer()
                    currentAvatar
                    Spacer()
                }
                PhotosPicker(selection: $pickedItem, matching: .images) {
                    Label("Choose photo", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(SecondaryButtonStyle())
                .onChange(of: pickedItem) { _, item in Task { await loadAvatar(item) } }
            }
            Section("Nickname") {
                TextField("Nickname", text: $displayName)
                    .textInputAutocapitalization(.words)
                Text("This is the name your mates see around CheekyPint.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
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
                Button("Save") { Task { await save() } }
                    .disabled(isSaving || usernameError != nil || sanitizer.sanitizeDisplayName(displayName).isEmpty)
            }
        }
        .onAppear(perform: populate)
    }

    @ViewBuilder
    private var currentAvatar: some View {
        if let avatarData {
            AvatarPreview(data: avatarData, fallbackInitials: displayName, size: 104)
                .overlay(Circle().stroke(Theme.Palette.accent.opacity(0.8), lineWidth: 2))
        } else if let profile = session.currentProfile {
            RemoteAvatar(
                url: container.avatarURL(for: profile.avatarPath),
                name: displayName.isEmpty ? profile.displayName : displayName,
                size: 104
            )
        } else {
            AvatarPreview(data: nil, fallbackInitials: displayName, size: 104)
        }
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

    private func loadAvatar(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let jpeg = ImageResizer.jpeg(from: image)
        else {
            errorMessage = "Couldn't read that photo. Try another image."
            return
        }
        avatarData = jpeg
        errorMessage = nil
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
            if let avatarData {
                try await container.profiles.uploadAvatar(avatarData)
            }
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
