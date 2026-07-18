import SwiftUI

/// A circular remote avatar with an initials fallback and cached loading. Uses AsyncImage
/// (URLCache-backed) so friend rows and headers stay light (master prompt §31).
struct RemoteAvatar: View {
    let url: URL?
    var name: String
    var size: CGFloat = 40

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                ZStack {
                    Theme.Palette.backgroundSecondary
                    Text(initials)
                        .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Theme.Palette.textSecondary.opacity(0.15), lineWidth: 1))
        .accessibilityHidden(true)
    }

    private var initials: String {
        let letters = name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? "🍺" : letters.uppercased()
    }
}
