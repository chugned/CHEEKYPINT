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

    /// Calls the `delete-account` Edge Function, which runs the `delete_account()` RPC as the
    /// caller (anonymise + tear down app data), then — with the service role, which never
    /// reaches this client — removes the caller's storage objects and deletes the auth user.
    /// Do NOT also call `rpcVoid("delete_account")` here: the function already runs it, and
    /// calling both would run the anonymisation twice.
    func deleteAccount() async throws {
        if await DemoWorld.shared.isActive { await DemoWorld.shared.deactivate(); return }
        try await data.invokeFunctionVoid("delete-account")
    }

    /// `<uid>/<uuid>.jpg` — mirrors `ComposePostSheet.storagePath(uid:)`'s shape and its
    /// lowercase requirement: the `avatars` storage policies
    /// (`20260101000950_storage.sql:21,26,27,31`) compare the folder segment to `auth.uid()::text`
    /// with plain `text` equality, and Postgres always renders that lowercase while
    /// `UUID.uuidString` is always uppercase. Extracted to a pure static function — same reason
    /// `storagePath` is static on `ComposePostSheet` — so the shape is testable without a network
    /// call.
    static func avatarStoragePath(uid: UUID) -> String {
        "\(uid.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
    }

    /// Upload a resized JPEG avatar into the caller's own folder and point the profile at it.
    @discardableResult
    func uploadAvatar(_ jpeg: Data) async throws -> String {
        if await DemoWorld.shared.isActive {
            let path = try Self.writeLocalAvatar(jpeg)
            _ = await DemoWorld.shared.updateProfile(ProfileUpdate(avatarPath: path))
            return path
        }
        let id = try await uid()
        let path = Self.avatarStoragePath(uid: id)
        _ = try await data.uploadObject(bucket: "avatars", path: path, data: jpeg, contentType: "image/jpeg")
        _ = try await updateProfile(ProfileUpdate(avatarPath: path))
        return path
    }

    /// Public URL for an avatar path (nil-safe).
    func avatarURL(for path: String?) -> URL? {
        guard let path else { return nil }
        if path.hasPrefix(Self.localAvatarPrefix) {
            return Self.localAvatarDirectory().appendingPathComponent(String(path.dropFirst(Self.localAvatarPrefix.count)))
        }
        return data.publicURL(bucket: "avatars", path: path)
    }

    /// Authenticated URL for a post-photo storage path (nil-safe). `post-images` is a private
    /// bucket whose `storage.objects` read policy is evaluated per request, so — unlike
    /// `avatarURL` above — this must go through the authenticated `/object/<bucket>/<path>` route
    /// rather than `/object/public/...`, which cannot serve a private bucket. `avatars` remaining
    /// public while `post-images` is private is deliberate and tracked, not an oversight.
    ///
    /// Demo/friend-circle mode's seeded photo needs the same `local-*/` escape hatch `avatarURL`
    /// uses below: friend-circle mode is a real user-facing mode that must need no backend, but
    /// without this a seeded `imagePath` shaped like a real storage path (e.g.
    /// `"<uid>/demo-pint.jpg"`) turns into a genuine Supabase Storage URL and gets fetched with no
    /// session — which is why that post used to render "Photo unavailable" instead of a photo.
    /// `postImageURL` is a plain sync function (called straight from `FeedView`'s body), so this
    /// checks the path's own shape rather than `DemoWorld.shared.isActive` — that's actor-isolated
    /// state a sync function can't `await`.
    func postImageURL(for path: String?) -> URL? {
        guard let path else { return nil }
        if path.hasPrefix(Self.localPostImagePrefix) {
            let filename = String(path.dropFirst(Self.localPostImagePrefix.count))
            // A photo composed in demo mode was written to Application Support; the seeded post's
            // photo ships in the bundle. Try the written file first, because a bundle lookup for a
            // just-picked photo can never succeed.
            let written = Self.localPostImageDirectory().appending(path: filename)
            if FileManager.default.fileExists(atPath: written.path) { return written }
            let name = (filename as NSString).deletingPathExtension
            let ext = (filename as NSString).pathExtension
            return Bundle.main.url(forResource: name, withExtension: ext)
        }
        return data.objectURL(bucket: "post-images", path: path)
    }

    /// Write a composed post's JPEG into Application Support so `postImageURL` can resolve it —
    /// mirrors `writeLocalAvatar` below exactly, but into its own directory. A photo picked in
    /// demo mode is never a bundle asset, so `Bundle.main.url(forResource:)` can never find it.
    func writeLocalPostImage(_ jpeg: Data) throws -> String {
        let filename = "\(UUID().uuidString).jpg"
        let directory = Self.localPostImageDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try jpeg.write(to: directory.appendingPathComponent(filename), options: [.atomic])
        return Self.localPostImagePrefix + filename
    }

    private static let localAvatarPrefix = "local-avatar/"
    static let localPostImagePrefix = "local-post-image/"

    private static func writeLocalAvatar(_ jpeg: Data) throws -> String {
        let filename = "\(UUID().uuidString).jpg"
        let directory = localAvatarDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try jpeg.write(to: directory.appendingPathComponent(filename), options: [.atomic])
        return localAvatarPrefix + filename
    }

    private static func localAvatarDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CheekyPintAvatars", isDirectory: true)
    }

    private static func localPostImageDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CheekyPintPostImages", isDirectory: true)
    }
}
