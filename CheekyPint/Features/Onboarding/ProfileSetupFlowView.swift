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

    private let sanitizer = ProfileTextSanitizer()

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
                TextField("Display name", text: $displayName)
                    .textInputAutocapitalization(.words)
                    .textFieldStyle(.roundedBorder)
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
            }
            Button(step == .privacy ? "Start pouring" : "Next") {
                if step == .privacy { Task { await commit() } }
                else { withAnimation { step = Step(rawValue: step.rawValue + 1) ?? .privacy } }
            }
            .buttonStyle(PintButtonStyle())
            .disabled(step == .name && sanitizer.sanitizeDisplayName(displayName).isEmpty)
        }
        .overlay { if isSaving { ProgressView().tint(Theme.Palette.accent) } }
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
        isSaving = true; errorMessage = nil
        defer { isSaving = false }
        do {
            if let avatarData { try await container.profiles.uploadAvatar(avatarData) }
            let cleanCity = sanitizer.sanitizeCity(city)
            try await container.profiles.updateProfile(ProfileUpdate(
                displayName: sanitizer.sanitizeDisplayName(displayName),
                city: cleanCity.isEmpty ? nil : cleanCity,
                timezone: TimeZone.current.identifier,
                locale: Locale.current.identifier
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
