import SwiftUI
import CheekyPintCore

/// The safe profile preview shown after resolving a friend token (master prompt §8). Only the
/// display name + avatar are shown; the request is sent explicitly by the user.
struct FriendPreviewView: View {
    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss
    let token: FriendToken

    @State private var preview: FriendPreviewDTO?
    @State private var phase: Phase = .loading
    private enum Phase: Equatable { case loading, ready, sent, failed(String) }

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            switch phase {
            case .loading:
                ProgressView().tint(Theme.Palette.accent)
            case .failed(let message):
                StatusView(systemImage: "questionmark.circle", title: "Couldn't find that code",
                           message: message, actionTitle: "Close") { dismiss() }
            case .ready, .sent:
                if let preview {
                    RemoteAvatar(url: container.avatarURL(for: preview.avatarPath), name: preview.displayName, size: 96)
                    Text(preview.displayName).font(Theme.Typography.largeTitle).foregroundStyle(Theme.Palette.textPrimary)
                    if phase == .sent {
                        Label("Request sent", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.Palette.success)
                        Button("Done") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                    } else {
                        Button("Send friend request") { Task { await send(to: preview.userId) } }
                            .buttonStyle(PintButtonStyle())
                    }
                }
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pubBackground()
        .navigationTitle("Add a mate")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .task { await resolve() }
    }

    private func resolve() async {
        do {
            let result = try await container.friends.resolveToken(token.rawValue)
            preview = result
            phase = .ready
        } catch let error as SupabaseError {
            phase = .failed(error.friendlyMessage)
        } catch {
            phase = .failed("Please try again.")
        }
    }

    private func send(to userID: UUID) async {
        do {
            try await container.friends.sendRequest(to: userID)
            Haptics.success()
            phase = .sent
        } catch let error as SupabaseError {
            phase = .failed(error.friendlyMessage)
        } catch {
            phase = .failed("Please try again.")
        }
    }
}
