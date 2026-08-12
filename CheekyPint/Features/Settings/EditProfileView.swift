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
    private static let sanitizer = ProfileTextSanitizer()

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
                    .accessibilityIdentifier("edit-profile-display-name")
                    .accessibilityLabel("Nickname")
                tooLongMessage(displayName, allowNewlines: false,
                               limit: ProfileTextSanitizer.displayNameMaxLength,
                               identifier: "edit-profile-display-name-error")
                Text("This is the name your mates see around CheekyPint.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            Section("Username") {
                TextField("username", text: $username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onChange(of: username) { _, value in validateUsername(value) }
                    .accessibilityIdentifier("edit-profile-username")
                    .accessibilityLabel("Username")
                if let usernameError {
                    Text(usernameError).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.warning)
                        .accessibilityIdentifier("edit-profile-username-error")
                }
            }
            Section("About") {
                TextField("Short bio", text: $bio, axis: .vertical).lineLimit(2...4)
                    .accessibilityIdentifier("edit-profile-bio")
                    .accessibilityLabel("Short bio")
                tooLongMessage(bio, allowNewlines: true, limit: ProfileTextSanitizer.bioMaxLength,
                               identifier: "edit-profile-bio-error")
            }
            Section {
                TextField("e.g. Graz, Austria", text: $city)
                    .accessibilityIdentifier("edit-profile-city")
                    .accessibilityLabel("Broad location")
                tooLongMessage(city, allowNewlines: false, limit: ProfileTextSanitizer.cityMaxLength,
                               identifier: "edit-profile-city-error")
            } header: {
                Text("Broad location")
            } footer: {
                Text("A broad area only — never your address. Off to friends by default.")
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(Theme.Palette.warning)
                    .accessibilityIdentifier("edit-profile-error")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.backgroundPrimary)
        .navigationTitle("Edit profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(isSaving || usernameError != nil || hasOverLongField
                              || Self.sanitizer.sanitizeDisplayName(displayName).isEmpty)
                    .accessibilityIdentifier("edit-profile-save")
                    .accessibilityLabel("Save profile")
            }
        }
        .onAppear(perform: populate)
    }

    // MARK: - Length gates
    //
    // The three free-text fields are saved through `ProfileTextSanitizer`, which truncates to a
    // *code-point* budget at grapheme-cluster boundaries. Truncating silently is the problem: the
    // `profiles` CHECK constraints are the only server-side bound (profile writes are a plain
    // PostgREST PATCH with no clamp), so whatever the client trims never reaches the server to be
    // complained about, and one grapheme cluster can be arbitrarily many code points — "a" plus a
    // long run of combining marks is a single visible character that blows a 160-code-point bio
    // budget, and truncation then yields "", i.e. a saved-empty bio the user never asked for.
    //
    // So the fields gate on the sanitised length before saving, exactly as the two feed composers
    // and the report sheet do, and say so on screen. The user's text is either saved whole or
    // refused with a reason; it is never quietly shortened or emptied.

    /// `static` (like `ComposePostSheet.canSubmit`) so "a 205-code-point bio blocks Save" is
    /// testable without a view instance — the whole point being that this input previously sailed
    /// through Save and stored `""`.
    static func hasOverLongField(displayName: String, bio: String, city: String) -> Bool {
        !sanitizer.fits(displayName, allowNewlines: false,
                        maxLength: ProfileTextSanitizer.displayNameMaxLength)
            || !sanitizer.fits(bio, allowNewlines: true, maxLength: ProfileTextSanitizer.bioMaxLength)
            || !sanitizer.fits(city, allowNewlines: false, maxLength: ProfileTextSanitizer.cityMaxLength)
    }

    private var hasOverLongField: Bool {
        Self.hasOverLongField(displayName: displayName, bio: bio, city: city)
    }

    /// Shown only when the field is actually over its limit. The count is spelled out because it can
    /// disagree wildly with what the field looks like — 41 code points can be one visible character
    /// — and "too long" with no number would be baffling in exactly that case.
    @ViewBuilder
    private func tooLongMessage(_ raw: String, allowNewlines: Bool, limit: Int, identifier: String) -> some View {
        // The same `fits` predicate the Save gate uses, so a field can never be refused without
        // saying so, or flagged without being refused.
        if !Self.sanitizer.fits(raw, allowNewlines: allowNewlines, maxLength: limit) {
            let length = Self.sanitizer.sanitizedLength(raw, allowNewlines: allowNewlines)
            Text(verbatim: "Too long: \(length)/\(limit). Accents and emoji can count as more than one character.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.warning)
                .accessibilityIdentifier(identifier)
                .accessibilityLabel("Too long: \(length) of \(limit) characters")
        }
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
        // `.disabled` alone is the weaker guard — a second tap can be dispatched from its own `Task`
        // before the first re-render — and here it would also decide whether text gets truncated,
        // so the length gate is re-checked in the action rather than trusted to the button state.
        guard !isSaving, !hasOverLongField else { return }
        isSaving = true; errorMessage = nil
        defer { isSaving = false }
        var update = ProfileUpdate(
            displayName: Self.sanitizer.sanitizeDisplayName(displayName),
            bio: Self.sanitizer.sanitizeBio(bio),
            city: Self.sanitizer.sanitizeCity(city)
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
