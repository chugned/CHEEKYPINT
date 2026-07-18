import Foundation
import CheekyPintCore

/// An in-memory backend for **demo mode** — lets the app run fully offline with seeded data so
/// you can explore every screen without Supabase or signing in. Repositories check
/// `DemoWorld.shared.isActive` and route here instead of the network. DEBUG-only entry points.
///
/// It reuses the real, tested `CheekyPintCore` (counter, period calculator, leaderboard builder),
/// so logging a pint really updates your totals and standings.
actor DemoWorld {
    static let shared = DemoWorld()
    private static let nicknameKey = "CheekyPint.friendCircleNickname"
    private static let avatarPathKey = "CheekyPint.friendCircleAvatarPath"

    private(set) var isActive = false

    // Seeded identities.
    static let aliceID = UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!
    static let barnabyID = UUID(uuidString: "00000000-0000-4000-8000-0000000000B2")!
    static let ceriID = UUID(uuidString: "00000000-0000-4000-8000-0000000000C3")!
    static let devID = UUID(uuidString: "00000000-0000-4000-8000-0000000000D4")!
    static let sessionID = UUID(uuidString: "00000000-0000-4000-8000-00000000F001")!
    static let kingsPubID = UUID(uuidString: "00000000-0000-4000-8000-00000000E001")!

    private var profile = Profile(
        id: aliceID, displayName: "Alice", username: "alice", bio: "Loves a quiet pint.",
        city: "Graz, Austria", countryCode: "AT",
        legalAgeConfirmedAt: Date(), timezone: TimeZone.current.identifier, locale: "en_GB")
    private var privacy = PrivacySettings.recommendedDefault(userId: aliceID)
    private var entries: [PintEntry] = []
    private var session: PubSession?

    var currentProfile: Profile { profile }

    /// Turn on friend-circle mode and seed data. Idempotent, but always refreshes the local
    /// surname so passing the phone around does not leave yesterday's culprit on the tab.
    func activate(surname: String? = nil) {
        configureProfile(for: surname)
        guard !isActive else { return }
        isActive = true

        let now = Date()
        session = PubSession(id: Self.sessionID, pubId: Self.kingsPubID, hostUserId: Self.aliceID,
                             name: "Friday at the Kings", status: .active,
                             startedAt: now.addingTimeInterval(-60 * 60))

        func entry(_ minsAgo: Double, serving: ServingType = .pint, alcoholFree: Bool = false,
                   pub: UUID? = nil, session: UUID? = nil) -> PintEntry {
            PintEntry(id: UUID(), userId: Self.aliceID,
                      pubId: pub, sessionId: session,
                      occurredAt: now.addingTimeInterval(-minsAgo * 60),
                      servingType: serving, alcoholFree: alcoholFree,
                      idempotencyKey: UUID().uuidString)
        }
        entries = [
            entry(45, pub: Self.kingsPubID, session: Self.sessionID),
            entry(20, pub: Self.kingsPubID, session: Self.sessionID),
            entry(10, serving: .ml330, alcoholFree: true),        // AF — excluded from totals
            entry(60 * 26, serving: .halfPint, pub: Self.kingsPubID), // earlier this week
            entry(60 * 24 * 9, pub: Self.kingsPubID),             // this month
        ]
    }

    func deactivate() { isActive = false }

    private func configureProfile(for surname: String?) {
        let clean = surname?.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedNickname = UserDefaults.standard.string(forKey: Self.nicknameKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = savedNickname.flatMap { $0.isEmpty ? nil : $0 }
            ?? clean.flatMap { $0.isEmpty ? nil : $0 }
            ?? "Alice"
        profile.displayName = displayName
        profile.username = Self.username(from: displayName)
        profile.avatarPath = UserDefaults.standard.string(forKey: Self.avatarPathKey)
        profile.bio = "Surname entered. Dignity optional."
        profile.legalAgeConfirmedAt = Date()
        profile.timezone = TimeZone.current.identifier
        profile.locale = Locale.current.identifier
    }

    private static func username(from displayName: String) -> String {
        let allowed = displayName.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }
        let raw = String(String.UnicodeScalarView(allowed))
        return raw.isEmpty ? "mate" : raw
    }

    // MARK: Profile

    func fetchProfile() -> Profile { profile }
    func fetchPrivacy() -> PrivacySettings { privacy }

    func updateProfile(_ update: ProfileUpdate) -> Profile {
        if let v = update.displayName {
            profile.displayName = v
            UserDefaults.standard.set(v, forKey: Self.nicknameKey)
        }
        if let v = update.username { profile.username = v }
        if let v = update.bio { profile.bio = v }
        if let v = update.avatarPath {
            profile.avatarPath = v
            UserDefaults.standard.set(v, forKey: Self.avatarPathKey)
        }
        if let v = update.city { profile.city = v }
        return profile
    }

    func updatePrivacy(_ update: PrivacyUpdate) {
        func vis(_ s: String?) -> Visibility? { s.flatMap(Visibility.init(rawValue:)) }
        if let v = vis(update.profileVisibility) { privacy.profileVisibility = v }
        if let v = vis(update.avatarVisibility) { privacy.avatarVisibility = v }
        if let v = vis(update.cityVisibility) { privacy.cityVisibility = v }
        if let v = vis(update.sessionTotalVisibility) { privacy.sessionTotalVisibility = v }
        if let v = vis(update.weeklyTotalVisibility) { privacy.weeklyTotalVisibility = v }
        if let v = vis(update.monthlyTotalVisibility) { privacy.monthlyTotalVisibility = v }
        if let v = vis(update.yearlyTotalVisibility) { privacy.yearlyTotalVisibility = v }
        if let v = vis(update.favouritePubsVisibility) { privacy.favouritePubsVisibility = v }
        if let v = vis(update.sharedSessionsVisibility) { privacy.sharedSessionsVisibility = v }
    }

    // MARK: Diary

    func createPint(idempotencyKey: String, occurredAt: Date, serving: ServingType,
                    volumeMl: Double?, alcoholFree: Bool, pubID: UUID?, sessionID: UUID?,
                    note: String?) -> PintEntry {
        if let existing = entries.first(where: { $0.idempotencyKey == idempotencyKey }) { return existing }
        let entry = PintEntry(id: UUID(), userId: Self.aliceID, pubId: pubID, sessionId: sessionID,
                              occurredAt: occurredAt, servingType: serving, volumeMl: volumeMl,
                              alcoholFree: alcoholFree, privateNote: note, idempotencyKey: idempotencyKey)
        entries.insert(entry, at: 0)
        return entry
    }

    func undoPint(id: UUID) -> PintEntry? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        entries[index].deletedAt = Date()
        return entries[index]
    }

    func liveEntries(limit: Int, before: Date?) -> [PintEntry] {
        entries.filter { $0.isActive && (before == nil || $0.occurredAt < before!) }
            .sorted { $0.occurredAt > $1.occurredAt }
            .prefix(limit).map { $0 }
    }

    func activeSession() -> PubSession? { session }

    // MARK: Friends

    func friends() -> [FriendDTO] {
        [
            FriendDTO(userId: Self.barnabyID, displayName: "Barnaby", avatarPath: nil,
                      city: nil, friendSince: Date().addingTimeInterval(-60 * 60 * 24 * 30)),
            FriendDTO(userId: Self.ceriID, displayName: "Ceri", avatarPath: nil,
                      city: nil, friendSince: Date().addingTimeInterval(-60 * 60 * 24 * 12)),
        ]
    }

    func pendingRequests() -> [PendingRequestDTO] {
        [PendingRequestDTO(friendshipId: UUID(), userId: Self.devID, displayName: "Dev",
                           avatarPath: nil, requestedAt: Date().addingTimeInterval(-3600))]
    }

    func friendProfile(_ id: UUID) -> FriendProfileDTO {
        let name = id == Self.barnabyID ? "Barnaby" : (id == Self.ceriID ? "Ceri" : "Mate")
        return FriendProfileDTO(userId: id, displayName: name, username: name.lowercased(),
                                bio: "A good egg.", avatarPath: nil, city: nil, countryCode: nil,
                                friendSince: Date().addingTimeInterval(-60 * 60 * 24 * 20))
    }

    func favouritePubs() -> [FavouritePubDTO] {
        [FavouritePubDTO(pubId: Self.kingsPubID, name: "The Kings Arms", city: "London",
                         visitCount: 3, lastVisit: Date(), sharedVisitCount: 1)]
    }

    // MARK: Leaderboard (uses the real tested builder)

    func leaderboard(period: LeaderboardPeriod, topCount: Int?) -> [LeaderboardRow] {
        let window = PeriodCalculator(profile: profile)
            .period(for: period, containing: Date(), session: session, now: Date())
        let myTotal = PintCounter().total(of: entries, in: window)

        // Fixed, neutral friend numbers; Ceri keeps her weekly total private to show the marker.
        func friendTotal(_ base: Int) -> PintTotal { PintTotal(recordedCount: base, standardServings: Double(base)) }
        let barnaby = LeaderboardParticipant(id: Self.barnabyID, displayName: "Barnaby", total: friendTotal(perPeriod(period, 1, 4, 11, 47)))
        let ceri = LeaderboardParticipant(id: Self.ceriID, displayName: "Ceri",
            total: period == .week ? nil : friendTotal(perPeriod(period, 0, 3, 9, 38)))
        let me = LeaderboardParticipant(
            id: Self.aliceID,
            displayName: profile.displayName,
            avatarPath: profile.avatarPath,
            isCurrentUser: true,
            total: myTotal
        )

        let builder = LeaderboardBuilder()
        if let topCount { return builder.preview([me, barnaby, ceri], topCount: topCount) }
        return builder.build([me, barnaby, ceri])
    }

    private func perPeriod(_ p: LeaderboardPeriod, _ session: Int, _ week: Int, _ month: Int, _ year: Int) -> Int {
        switch p { case .session: session; case .week: week; case .month: month; case .year: year }
    }

    // MARK: Pubs

    func pubSearch() -> [PubSearchResult] {
        [
            PubSearchResult(name: "The Kings Arms", address: "25 Roupell St, London", city: "London",
                            countryCode: "GB", latitude: 51.5045, longitude: -0.1105),
            PubSearchResult(name: "Zum Goldenen Krug", address: "Hauptplatz 1, Graz", city: "Graz",
                            countryCode: "AT", latitude: 47.0707, longitude: 15.4395),
        ]
    }

    func persist(_ result: PubSearchResult) -> Pub {
        Pub(id: result.name.contains("Kings") ? Self.kingsPubID : UUID(),
            name: result.name, formattedAddress: result.address, city: result.city,
            countryCode: result.countryCode, latitude: result.latitude, longitude: result.longitude)
    }

    func newFriendToken() -> FriendToken { FriendToken.generate() }
}
