import SwiftUI
import CheekyPintCore

/// "My QR" (master prompt §8). Shows the friend QR (an opaque-token deep link — no personal
/// data), the shareable code, and a Regenerate action that revokes the old token. The raw token
/// is cached locally (Keychain) so reopening doesn't invalidate it; only Regenerate does.
struct MyQRView: View {
    @Environment(\.container) private var container
    @Environment(SessionController.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var token: FriendToken?
    @State private var isLoading = true
    @State private var errorMessage: String?

    private let store = KeychainStore(service: "app.cheekypint.friendcode")

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Spacing.lg) {
                if let token {
                    QRCodeView(url: container.deepLinkParser.addFriendURL(token))
                        .frame(maxWidth: 260)
                    codeRow(token)
                    ShareLink(item: container.deepLinkParser.addFriendURL(token, universal: true)) {
                        Label("Share invite link", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                } else if isLoading {
                    ProgressView().tint(Theme.Palette.accent)
                } else {
                    StatusView(systemImage: "qrcode", title: "Couldn't load your code",
                               message: errorMessage, actionTitle: "Retry") { Task { await load(forceNew: false) } }
                }
                Spacer()
                Button("Regenerate code", role: .destructive) { Task { await load(forceNew: true) } }
                    .font(Theme.Typography.callout)
            }
            .padding(Theme.Spacing.lg)
            .pubBackground()
            .navigationTitle("My QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                container.analytics.track(.friendQROpened)
                await load(forceNew: false)
            }
        }
    }

    private func codeRow(_ token: FriendToken) -> some View {
        HStack {
            Text(token.rawValue.prefix(10) + "…")
                .font(Theme.Typography.caption.monospaced())
                .foregroundStyle(Theme.Palette.textSecondary)
            Spacer()
            Button {
                UIPasteboard.general.string = token.rawValue
                Haptics.soft()
            } label: { Label("Copy code", systemImage: "doc.on.doc") }
                .font(Theme.Typography.caption)
                .tint(Theme.Palette.accent)
        }
        .coasterCard()
    }

    private var account: String { session.currentProfile?.id.uuidString ?? "me" }

    private func load(forceNew: Bool) async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }

        if !forceNew, let cached = store.data(for: account).flatMap({ String(data: $0, encoding: .utf8) }),
           let existing = FriendToken(rawValue: cached) {
            token = existing
            return
        }
        do {
            let fresh = try await container.profiles.regenerateFriendToken()
            store.set(Data(fresh.rawValue.utf8), for: account)
            token = fresh
        } catch let error as SupabaseError {
            errorMessage = error.friendlyMessage
        } catch {
            errorMessage = "Please try again."
        }
    }
}
