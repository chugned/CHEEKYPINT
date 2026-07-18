import SwiftUI
import CheekyPintCore

/// The Profile tab — a hub for the user's own identity, diary, QR, and settings (master prompt §6).
struct ProfileView: View {
    @Environment(SessionController.self) private var session
    @Environment(\.container) private var container
    @State private var showQR = false

    var body: some View {
        NavigationStack {
            List {
                if let profile = session.currentProfile {
                    Section {
                        HStack(spacing: Theme.Spacing.md) {
                            RemoteAvatar(url: container.avatarURL(for: profile.avatarPath), name: profile.displayName, size: 56)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.displayName).font(Theme.Typography.title).foregroundStyle(Theme.Palette.textPrimary)
                                if let username = profile.username { Text("@\(username)").font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textSecondary) }
                                if let city = profile.city { Text(city).font(Theme.Typography.caption).foregroundStyle(Theme.Palette.textSecondary) }
                            }
                            Spacer()
                            NavigationLink { EditProfileView() } label: {
                                Image(systemName: "pencil.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(Theme.Palette.accent)
                            }
                            .accessibilityLabel("Edit nickname and profile picture")
                        }
                        .padding(.vertical, Theme.Spacing.xxs)
                    }
                }
                Section {
                    Button { showQR = true } label: { Label("My QR code", systemImage: "qrcode") }
                    NavigationLink { PersonalHistoryView() } label: { Label("My diary", systemImage: "book.closed") }
                }
                Section {
                    NavigationLink { SettingsView() } label: { Label("Settings", systemImage: "gearshape") }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.backgroundPrimary)
            .navigationTitle("Profile")
        }
        .sheet(isPresented: $showQR) { MyQRView() }
    }
}
