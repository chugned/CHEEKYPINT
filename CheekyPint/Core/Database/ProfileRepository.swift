import Foundation
import CheekyPintCore

/// Partial profile update — only non-nil fields are sent (PostgREST PATCH).
struct ProfileUpdate: Encodable, Sendable {
    var displayName: String?
    var username: String?
    var bio: String?
    var avatarPath: String?
    var city: String?
    var countryCode: String?
    var timezone: String?
    var locale: String?
    var legalAgeConfirmedAt: Date?
}

struct PrivacyUpdate: Encodable, Sendable {
    var profileVisibility: String?
    var avatarVisibility: String?
    var cityVisibility: String?
    var sessionTotalVisibility: String?
    var weeklyTotalVisibility: String?
    var monthlyTotalVisibility: String?
    var yearlyTotalVisibility: String?
    var favouritePubsVisibility: String?
    var sharedSessionsVisibility: String?
}

/// Reads/writes the caller's own profile + privacy rows (RLS: self only) and manages the
/// friend token.
struct ProfileRepository: Sendable {
    let data: SupabaseData

    private func uid() async throws -> UUID {
        guard let uid = await data.auth.currentUserID else { throw SupabaseError.notAuthenticated }
        return uid
    }

    func fetchMyProfile() async throws -> Profile {
        if await DemoWorld.shared.isActive { return await DemoWorld.shared.fetchProfile() }
        let id = try await uid()
        let rows: [Profile] = try await data.select("profiles", query: [
            URLQueryItem(name: "id", value: "eq.\(id)"),
            URLQueryItem(name: "select", value: "*"),
        ])
        guard let profile = rows.first else { throw SupabaseError.notFound }
        return profile
    }

    func fetchMyPrivacy() async throws -> PrivacySettings {
        if await DemoWorld.shared.isActive { return await DemoWorld.shared.fetchPrivacy() }
        let id = try await uid()
        let rows: [PrivacySettings] = try await data.select("privacy_settings", query: [
            URLQueryItem(name: "user_id", value: "eq.\(id)"),
            URLQueryItem(name: "select", value: "*"),
        ])
        guard let settings = rows.first else { throw SupabaseError.notFound }
        return settings
    }

    @discardableResult
    func updateProfile(_ update: ProfileUpdate) async throws -> Profile {
        if await DemoWorld.shared.isActive { return await DemoWorld.shared.updateProfile(update) }
        let id = try await uid()
        let rows: [Profile] = try await data.patch("profiles", values: update, match: [
            URLQueryItem(name: "id", value: "eq.\(id)"),
        ])
        guard let profile = rows.first else { throw SupabaseError.notFound }
        return profile
    }

    func updatePrivacy(_ update: PrivacyUpdate) async throws {
        if await DemoWorld.shared.isActive { await DemoWorld.shared.updatePrivacy(update); return }
        let id = try await uid()
        let _: [PrivacySettings] = try await data.patch("privacy_settings", values: update, match: [
            URLQueryItem(name: "user_id", value: "eq.\(id)"),
        ])
    }

    /// Records the legal-age confirmation (master prompt §3, §17). Stored as a timestamp.
    func confirmLegalAge() async throws {
        _ = try await updateProfile(ProfileUpdate(legalAgeConfirmedAt: Date()))
    }

    /// Mint a fresh friend token and return the deep-link URL to render as a QR.
    func regenerateFriendToken() async throws -> FriendToken {
        if await DemoWorld.shared.isActive { return await DemoWorld.shared.newFriendToken() }
        let raw: String = try await data.rpc("regenerate_friend_token", params: EmptyBody())
        guard let token = FriendToken(rawValue: raw) else { throw SupabaseError.decoding("bad token") }
        return token
    }

    func deleteAccount() async throws {
        if await DemoWorld.shared.isActive { await DemoWorld.shared.deactivate(); return }
        try await data.rpcVoid("delete_account")
    }

    /// Upload a resized JPEG avatar into the caller's own folder and point the profile at it.
    @discardableResult
    func uploadAvatar(_ jpeg: Data) async throws -> String {
        if await DemoWorld.shared.isActive { return "demo/avatar.jpg" }
        let id = try await uid()
        let path = "\(id)/\(UUID().uuidString).jpg"
        _ = try await data.uploadObject(bucket: "avatars", path: path, data: jpeg, contentType: "image/jpeg")
        _ = try await updateProfile(ProfileUpdate(avatarPath: path))
        return path
    }

    /// Public URL for an avatar path (nil-safe).
    func avatarURL(for path: String?) -> URL? {
        guard let path else { return nil }
        return data.publicURL(bucket: "avatars", path: path)
    }
}
