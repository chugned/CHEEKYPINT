import Foundation

/// A resolved inbound link. The token still has to be redeemed server-side (which applies
/// rate limits, expiry, and block checks); parsing only recognises shape and extracts the
/// opaque token.
public enum DeepLink: Sendable, Equatable {
    case addFriend(FriendToken)
    case joinSession(FriendToken)
}

/// Builds and parses CheekyPint links in both custom-scheme and universal-link forms.
///
/// - Custom scheme: `cheekypint://friend/<token>`, `cheekypint://session/<token>`
/// - Universal link (fallback for people without the app): `https://cheekypint.app/friend/<token>`
public struct DeepLinkParser: Sendable {
    public static let scheme = "cheekypint"
    public static let universalHost = "cheekypint.app"

    private enum Kind: String {
        case friend
        case session
    }

    public init() {}

    // MARK: - Parse

    public func parse(_ url: URL) -> DeepLink? {
        guard let (kind, tokenString) = extract(from: url),
              let token = FriendToken(rawValue: tokenString) else { return nil }
        switch kind {
        case .friend: return .addFriend(token)
        case .session: return .joinSession(token)
        }
    }

    private func extract(from url: URL) -> (Kind, String)? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        switch components.scheme?.lowercased() {
        case Self.scheme:
            // cheekypint://<kind>/<token>  → host is the kind, first path segment is the token.
            guard let host = components.host, let kind = Kind(rawValue: host) else { return nil }
            let token = components.path.split(separator: "/").first.map(String.init)
            guard let token else { return nil }
            return (kind, token)

        case "https":
            // https://cheekypint.app/<kind>/<token>
            guard components.host?.lowercased() == Self.universalHost else { return nil }
            let segments = components.path.split(separator: "/").map(String.init)
            guard segments.count == 2, let kind = Kind(rawValue: segments[0]) else { return nil }
            return (kind, segments[1])

        default:
            return nil
        }
    }

    // MARK: - Build

    public func addFriendURL(_ token: FriendToken, universal: Bool = false) -> URL {
        url(kind: .friend, token: token, universal: universal)
    }

    public func joinSessionURL(_ token: FriendToken, universal: Bool = false) -> URL {
        url(kind: .session, token: token, universal: universal)
    }

    private func url(kind: Kind, token: FriendToken, universal: Bool) -> URL {
        var components = URLComponents()
        if universal {
            components.scheme = "https"
            components.host = Self.universalHost
            components.path = "/\(kind.rawValue)/\(token.rawValue)"
        } else {
            components.scheme = Self.scheme
            components.host = kind.rawValue
            components.path = "/\(token.rawValue)"
        }
        // Safe to force-unwrap: scheme/host/path are all controlled and URL-safe here.
        guard let result = components.url else {
            preconditionFailure("Failed to build CheekyPint deep link from controlled components")
        }
        return result
    }
}
