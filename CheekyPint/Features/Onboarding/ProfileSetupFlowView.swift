import SwiftUI
import PhotosUI
import CheekyPintCore

/// Post-auth onboarding (master prompt §17, steps 5–9): display name → optional photo →
/// optional broad city → initial privacy (recommended defaults, city off) → done. Photo and
/// city are skippable.
struct ProfileSetupFlowView: View {
    @Environment(SessionController.self) private var session
    @Environment(\.container) private var container

    private enum Step: Int, CaseIterable { case name, photo, city, privacy }
    @State private var step: Step = .name

    @State private var displayName = ""
    @State private var city = ""
    @State private var pickedItem: PhotosPickerItem?
    @State private var avatarData: Data?
    @State private var privacy = PrivacySettings.recommendedDefault(userId: UUID())
    @State private var isSaving = false
    @State private var errorMessage: String?

    private static let sanitizer = ProfileTextSanitizer()

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Spacing.lg) {
                ProgressView(value: Double(step.rawValue + 1), total: Double(Step.allCases.count))
                    .tint(Theme.Palette.accent)
                content
                Spacer()
                if let errorMessage {
                    Text(errorMessage).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.warning)
                }
                actionBar
            }
            .padding(Theme.Spacing.lg)
            .pubBackground()
            .navigationTitle("Set up your stool")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .name:
            field(title: "What should mates call you?", systemImage: "person.fill") {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    TextField("Display name", text: $displayName)
                        .textInputAutocapitalization(.words)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("profile-setup-display-name")
                        .accessibilityLabel("Display name")
                    tooLongMessage(displayName, allowNewlines: false,
                                   limit: ProfileTextSanitizer.displayNameMaxLength,
                                   identifier: "profile-setup-display-name-error")
                }
            }
        case .photo:
            VStack(spacing: Theme.Spacing.md) {
                sectionHeader("Add a photo (optional)", systemImage: "camera.fill")
                AvatarPreview(data: avatarData, fallbackInitials: displayName)
                PhotosPicker("Choose photo", selection: $pickedItem, matching: .images)
                    .buttonStyle(SecondaryButtonStyle())
                    .onChange(of: pickedItem) { _, item in Task { await loadAvatar(item) } }
            }
        case .city:
            field(title: "Where's your local? (optional)", systemImage: "mappin.and.ellipse") {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    TextField("e.g. Graz, Austria", text: $city)
                        .textInputAutocapitalization(.words)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("profile-setup-city")
                        .accessibilityLabel("Broad location")
                    tooLongMessage(city, allowNewlines: false,
                                   limit: ProfileTextSanitizer.cityMaxLength,
                                   identifier: "profile-setup-city-error")
                    Text("A broad area only — never your address. Off to friends by default.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
        case .privacy:
            PrivacyChoicesView(privacy: $privacy)
        }
    }

    private var actionBar: some View {
        HStack(spacing: Theme.Spacing.md) {
            if step != .name {
                Button("Back") { withAnimation { step = Step(rawValue: step.rawValue - 1) ?? .name } }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("profile-setup-back")
                    .accessibilityLabel("Back")
            }
            Button(step == .privacy ? "Start pouring" : "Next") {
                if step == .privacy { Task { await commit() } }
                else { withAnimation { step = Step(rawValue: step.rawValue + 1) ?? .privacy } }
            }
            .buttonStyle(PintButtonStyle())
            .disabled(hasOverLongField
                      || (step == .name && Self.sanitizer.sanitizeDisplayName(displayName).isEmpty))
            .accessibilityIdentifier("profile-setup-next")
            .accessibilityLabel(step == .privacy ? "Start pouring" : "Next")
        }
        .overlay { if isSaving { ProgressView().tint(Theme.Palette.accent) } }
    }

    // MARK: - Length gates
    //
    // Both fields are saved through `ProfileTextSanitizer`, which truncates to a *code-point* budget
    // — and one grapheme cluster can be arbitrarily many code points, so a single visible character
    // built from combining marks can exceed the 40-code-point name budget and truncate to "". That
    // used to grey out Next with nothing on screen to explain why, while the field plainly contained
    // text. Gating on the sanitised length instead (as the feed composers and the report sheet do)
    // means the same input still blocks Next, but now says what is wrong.
    //
    // `hasOverLongField` covers both fields on every step rather than only the visible one: the last
    // step writes both, so "Start pouring" must not be reachable with either over its limit.

    /// `static` so "a 52-code-point display name blocks Next" is testable without a view instance.
    /// Gates on `ProfileTextSanitizer.fits`, the same predicate `EditProfileView` uses for the same
    /// two columns — two screens writing one column through two hand-rolled comparisons is how the
    /// user-report path drifted from the content ones.
    static func hasOverLongField(displayName: String, city: String) -> Bool {
        !sanitizer.fits(displayName, allowNewlines: false,
                        maxLength: ProfileTextSanitizer.displayNameMaxLength)
            || !sanitizer.fits(city, allowNewlines: false, maxLength: ProfileTextSanitizer.cityMaxLength)
    }

    private var hasOverLongField: Bool {
        Self.hasOverLongField(displayName: displayName, city: city)
    }

    /// Shown only when the field is over its limit. The count is spelled out because it can disagree
    /// wildly with what the field looks like — 41 code points can be one visible character.
    @ViewBuilder
    private func tooLongMessage(_ raw: String, allowNewlines: Bool, limit: Int, identifier: String) -> some View {
        if !Self.sanitizer.fits(raw, allowNewlines: allowNewlines, maxLength: limit) {
            let length = Self.sanitizer.sanitizedLength(raw, allowNewlines: allowNewlines)
            Text(verbatim: "Too long: \(length)/\(limit). Accents and emoji can count as more than one character.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.warning)
                .accessibilityIdentifier(identifier)
                .accessibilityLabel("Too long: \(length) of \(limit) characters")
        }
    }

    // MARK: Helpers

    private func field<Inner: View>(title: String, systemImage: String, @ViewBuilder inner: () -> Inner) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            sectionHeader(title, systemImage: systemImage)
            inner()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(Theme.Typography.title)
            .foregroundStyle(Theme.Palette.textPrimary)
            .labelStyle(.titleAndIcon)
    }

    private func loadAvatar(_ item: PhotosPickerItem?) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        avatarData = ImageResizer.jpeg(from: image)
    }

    private func commit() async {
        // Re-checked in the action, not left to `.disabled`: a second tap can be dispatched from its
        // own `Task` before the first re-render, and here the gate decides whether text is truncated.
        guard !isSaving, !hasOverLongField else { return }
        isSaving = true; errorMessage = nil
        defer { isSaving = false }
        do {
            if let avatarData { try await container.profiles.uploadAvatar(avatarData) }
            let cleanCity = Self.sanitizer.sanitizeCity(city)
            try await container.profiles.updateProfile(ProfileUpdate(
                displayName: Self.sanitizer.sanitizeDisplayName(displayName),
                city: cleanCity.isEmpty ? nil : cleanCity,
                timezone: TimeZone.current.identifier,
                locale: Locale.current.identifier,
                // The legal-age confirmation the user gave before signing in (§17's third screen,
                // which is the only way to reach this flow) is written here, in the same PATCH as
                // the name — see `SessionController.pendingAgeConfirmed`. Unconditional rather
                // than gated on that in-memory flag, which is lost if the app is killed part-way
                // through setup: gating on it would leave such a user permanently in `.onboarding`,
                // since the column that ends this phase would never be filled in.
                legalAgeConfirmedAt: Date()
            ))
            try await container.profiles.updatePrivacy(privacy.asUpdate())
            await session.completeOnboarding()
        } catch let error as SupabaseError {
            errorMessage = error.friendlyMessage
        } catch {
            errorMessage = "Couldn't save your details. Please try again."
        }
    }
}

/// A circular avatar preview with initials fallback.
struct AvatarPreview: View {
    var data: Data?
    var fallbackInitials: String
    var size: CGFloat = 96

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Theme.Palette.backgroundSecondary
                    Text(initials).font(Theme.Typography.title).foregroundStyle(Theme.Palette.textSecondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityLabel("Profile photo")
    }

    private var initials: String {
        let parts = fallbackInitials.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? "🍺" : letters.uppercased()
    }
}

extension PrivacySettings {
    /// Map the settings the user toggled during onboarding to a PATCH body.
    func asUpdate() -> PrivacyUpdate {
        PrivacyUpdate(
            profileVisibility: profileVisibility.rawValue,
            avatarVisibility: avatarVisibility.rawValue,
            cityVisibility: cityVisibility.rawValue,
            sessionTotalVisibility: sessionTotalVisibility.rawValue,
            weeklyTotalVisibility: weeklyTotalVisibility.rawValue,
            monthlyTotalVisibility: monthlyTotalVisibility.rawValue,
            yearlyTotalVisibility: yearlyTotalVisibility.rawValue,
            favouritePubsVisibility: favouritePubsVisibility.rawValue,
            sharedSessionsVisibility: sharedSessionsVisibility.rawValue
        )
    }
}
