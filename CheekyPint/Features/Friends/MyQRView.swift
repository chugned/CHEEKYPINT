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

    private let store = KeychainStore(service: Self.keychainService)
    /// This feature's own Keychain service — never `app.cheekypint.session`, which holds the auth
    /// tokens.
    static let keychainService = "app.cheekypint.friendcode"

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

    /// Where this screen's cached raw friend token lives — or why it cannot be looked up at all.
    ///
    /// Deliberately not `String?`: there is no correct value to fall back to, and an enum that
    /// carries the refusal makes that structural rather than a convention a later caller can
    /// undo with `?? something`.
    enum CacheKey: Equatable {
        /// Namespaced to this feature and scoped to exactly one account.
        case account(String)
        /// No profile loaded, so nothing to scope the entry to. `load(forceNew:)` shows `message`
        /// and touches neither the Keychain nor the network.
        case noAccount(message: String)
    }

    /// The Keychain key for `id`'s cached friend token.
    ///
    /// This used to be `session.currentProfile?.id.uuidString ?? "me"`, and both halves were
    /// wrong. The bare UUID carried no namespace, so nothing in the key itself said which feature
    /// owned the entry. And `"me"` was a **shared** slot: any two accounts that reached this screen
    /// without a loaded profile would read and write the same entry, so the second would be shown
    /// the first account's raw friend token. That token is a credential — whoever holds it can
    /// resolve it to your profile and send you a friend request — so the fallback was a
    /// cross-account leak one new presentation site away from being real. (Unreachable today:
    /// `MainTabView` renders only in `.ready(profile)`, `SessionController.swift:178`, and this
    /// view is presented only from `FriendsView`'s toolbar.)
    ///
    /// So: no fallback. A missing profile refuses, rather than quietly sharing a bucket.
    static func cacheKey(forProfile id: UUID?) -> CacheKey {
        guard let id else {
            return .noAccount(message: "We can't tell which account this is, so we won't show a " +
                                      "code that might not be yours. Sign out, sign back in, and " +
                                      "try again.")
        }
        return .account("friendcode.\(id.uuidString)")
    }

    private func load(forceNew: Bool) async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }

        let account: String
        switch Self.cacheKey(forProfile: session.currentProfile?.id) {
        case .account(let key):
            account = key
        case .noAccount(let message):
            // Clears any code already on screen: without an account to attribute it to we cannot
            // say it belongs to whoever is looking, and `errorMessage` is only rendered when
            // `token` is nil.
            token = nil
            errorMessage = message
            return
        }

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
