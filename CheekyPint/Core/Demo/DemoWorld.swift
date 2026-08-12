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
    static let krugPubID = UUID(uuidString: "00000000-0000-4000-8000-00000000E002")!
    static let officePubID = UUID(uuidString: "00000000-0000-4000-8000-00000000E003")!

    private var profile = Profile(
        id: aliceID, displayName: "Alice", username: "alice", bio: "Loves a quiet pint.",
        city: "Graz, Austria", countryCode: "AT",
        legalAgeConfirmedAt: Date(), timezone: TimeZone.current.identifier, locale: "en_GB")
    private var privacy = PrivacySettings.recommendedDefault(userId: aliceID)
    private var entries: [PintEntry] = []
    private var session: PubSession?
    private var pubs: [UUID: Pub] = [:]
    private var nudges: [DemoNudge] = []
    private var feedPosts: [DemoPost] = []
    private var feedComments: [DemoComment] = []

    private struct DemoNudge {
        let id: UUID
        let senderID: UUID
        let recipientID: UUID
        let createdAt: Date
    }

    /// A demo feed post. Deliberately its own shape (not `FeedPostDTO`): `displayName` and
    /// `avatarPath` are resolved from `authorID` at read time via `feedDisplayName`/
    /// `feedAvatarPath` so Alice's own posts stay in sync with a surname entered after seeding,
    /// and `commentCount` is derived from `feedComments` rather than stored, so `addComment`/
    /// `deleteComment` can't drift out of sync with the count they imply.
    private struct DemoPost {
        let id: UUID
        let authorID: UUID
        var body: String?
        var imagePath: String?
        var placeLabel: String?
        let pubID: UUID?
        let createdAt: Date
        let createdAtRaw: String
        var cheersCount: Int
        var viewerHasCheered: Bool
        var deletedAt: Date?
    }

    private struct DemoComment {
        let id: UUID
        let postID: UUID
        let authorID: UUID
        let body: String
        let createdAt: Date
        let createdAtRaw: String
        let mentionedUserIds: [UUID]
        var deletedAt: Date?
    }

    /// Matches production formatting closely enough for round-trip purposes: fixed-width
    /// fractional seconds in a fixed (UTC) offset, so lexical and chronological order agree —
    /// `feedPage`'s cursor comparison relies on that for its own bookkeeping here.
    private static let feedTimestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    var currentProfile: Profile { profile }

    /// Turn on friend-circle mode and seed data. Idempotent, but always refreshes the local
    /// surname so passing the phone around does not leave yesterday's culprit on the tab.
    func activate(surname: String? = nil) {
        configureProfile(for: surname)
        guard !isActive else { return }
        isActive = true

        let now = Date()
        pubs = Self.seedPubs()
        session = PubSession(id: Self.sessionID, pubId: Self.kingsPubID, hostUserId: Self.aliceID,
                             name: "Friday at the Kings", status: .active,
                             startedAt: now.addingTimeInterval(-60 * 60))

        func entry(_ minsAgo: Double, user: UUID, beer: String, serving: ServingType = .pint,
                   alcoholFree: Bool = false, pub: UUID? = nil, session: UUID? = nil) -> PintEntry {
            PintEntry(id: UUID(), userId: user,
                      pubId: pub, sessionId: session,
                      occurredAt: now.addingTimeInterval(-minsAgo * 60),
                      servingType: serving, alcoholFree: alcoholFree,
                      privateNote: "[Beer: \(beer)] logged from friend-circle demo.",
                      idempotencyKey: UUID().uuidString)
        }
        entries = [
            entry(45, user: Self.aliceID, beer: "Puntigamer", pub: Self.kingsPubID, session: Self.sessionID),
            entry(20, user: Self.aliceID, beer: "Stiegl", pub: Self.kingsPubID, session: Self.sessionID),
            entry(10, user: Self.aliceID, beer: "Hoegaarden", serving: .ml330, alcoholFree: true),
            entry(60 * 26, user: Self.aliceID, beer: "Guinness", serving: .halfPint, pub: Self.kingsPubID),
            entry(60 * 24 * 9, user: Self.aliceID, beer: "Pilsner Urquell", pub: Self.officePubID),
            entry(60 * 24 * 12, user: Self.aliceID, beer: "Ottakringer Helles", pub: Self.kingsPubID),
            entry(60 * 24 * 15, user: Self.aliceID, beer: "Puntigamer", pub: Self.officePubID),
            entry(60 * 24 * 22, user: Self.aliceID, beer: "Stiegl", pub: Self.krugPubID),
            entry(8, user: Self.barnabyID, beer: "Guinness", pub: Self.kingsPubID, session: Self.sessionID),
            entry(65, user: Self.barnabyID, beer: "Stella Artois", pub: Self.kingsPubID, session: Self.sessionID),
            entry(60 * 7, user: Self.barnabyID, beer: "Peroni Nastro Azzurro", pub: Self.officePubID),
            entry(60 * 24 * 4, user: Self.barnabyID, beer: "Guinness", pub: Self.kingsPubID),
            entry(60 * 24 * 6, user: Self.barnabyID, beer: "Carlsberg", pub: Self.krugPubID),
            entry(60 * 24 * 14, user: Self.barnabyID, beer: "Stella Artois", pub: Self.kingsPubID),
            entry(18, user: Self.ceriID, beer: "Pilsner Urquell", pub: Self.krugPubID),
            entry(80, user: Self.ceriID, beer: "Ottakringer Helles", pub: Self.krugPubID),
            entry(60 * 30, user: Self.ceriID, beer: "Guinness", pub: Self.kingsPubID),
            entry(60 * 24 * 3, user: Self.ceriID, beer: "Hoegaarden", pub: Self.krugPubID),
            entry(60 * 24 * 8, user: Self.ceriID, beer: "Pilsner Urquell", pub: Self.officePubID),
            entry(60 * 24 * 20, user: Self.ceriID, beer: "Ottakringer Helles", pub: Self.krugPubID),
        ]
        // Seed one incoming Nudge so the interaction is immediately visible in demo and
        // friend-circle mode. Sending it back turns it into an outgoing Nudge.
        nudges = [
            DemoNudge(
                id: UUID(),
                senderID: Self.barnabyID,
                recipientID: Self.aliceID,
                createdAt: now.addingTimeInterval(-8 * 60)
            )
        ]

        // Three posts of varied shape, so paging/ordering/toggle are all exercisable offline:
        // Alice's carries a place label, two Cheers (one of them the viewer's own, so both
        // toggle directions are reachable by hand) and the one seeded comment; Barnaby's
        // carries a photo path instead of a place; Ceri's is plain text only.
        func post(_ minsAgo: Double, author: UUID, body: String?, imagePath: String? = nil,
                  placeLabel: String? = nil, pubID: UUID? = nil, cheers: Int = 0, cheered: Bool = false) -> DemoPost {
            let createdAt = now.addingTimeInterval(-minsAgo * 60)
            return DemoPost(id: UUID(), authorID: author, body: body, imagePath: imagePath,
                            placeLabel: placeLabel, pubID: pubID, createdAt: createdAt,
                            createdAtRaw: Self.feedTimestampStyle.format(createdAt),
                            cheersCount: cheers, viewerHasCheered: cheered, deletedAt: nil)
        }
        let alicePost = post(30, author: Self.aliceID,
                             body: "Friday pint at the usual spot — cheers all round!",
                             placeLabel: "The Kings Arms, London", pubID: Self.kingsPubID,
                             cheers: 2, cheered: true)
        let barnabyPost = post(90, author: Self.barnabyID,
                               body: "Snapped this one before it went flat.",
                               imagePath: ProfileRepository.localPostImagePrefix + "demo-pint.png")
        let ceriPost = post(180, author: Self.ceriID, body: "Quiet one tonight.")
        // Filler posts, older than all three named posts above so they never bump Alice's/
        // Barnaby's/Ceri's out of page one: `FeedViewModel`'s default `pageSize` is 20, and until
        // now demo mode only ever seeded 3 posts total, so `feedPage`'s cursor branch (`p_before`
        // non-nil) and `loadMore`'s append/`hasMore` recomputation had zero execution in any
        // suite — the branch's headline data-path claim, untested. 20 fillers (23 posts total)
        // makes `loadMore` genuinely fire against the real demo backend: page one is full at 20,
        // `hasMore` is true, and page two carries the remaining 3.
        let fillerPosts = (0..<20).map { index in
            post(180 + Double(index + 1) * 60, author: Self.ceriID, body: "Another quiet one, #\(index + 1).")
        }
        feedPosts = [alicePost, barnabyPost, ceriPost] + fillerPosts

        let commentAt = now.addingTimeInterval(-20 * 60)
        feedComments = [
            DemoComment(id: UUID(), postID: alicePost.id, authorID: Self.barnabyID,
                       body: "Get one in for me!", createdAt: commentAt,
                       createdAtRaw: Self.feedTimestampStyle.format(commentAt),
                       mentionedUserIds: [], deletedAt: nil)
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

    private static func seedPubs() -> [UUID: Pub] {
        [
            Self.kingsPubID: Pub(
                id: Self.kingsPubID,
                name: "The Kings Arms",
                formattedAddress: "25 Roupell St, London",
                city: "London",
                countryCode: "GB",
                latitude: 51.5045,
                longitude: -0.1105
            ),
            Self.krugPubID: Pub(
                id: Self.krugPubID,
                name: "Zum Goldenen Krug",
                formattedAddress: "Hauptplatz 1, Graz",
                city: "Graz",
                countryCode: "AT",
                latitude: 47.0707,
                longitude: 15.4395
            ),
            Self.officePubID: Pub(
                id: Self.officePubID,
                name: "The Office Pub",
                formattedAddress: "Trauttmansdorffgasse 3, Graz",
                city: "Graz",
                countryCode: "AT",
                latitude: 47.0710,
                longitude: 15.4402
            ),
        ]
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
            .filter { $0.userId == Self.aliceID }
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

    // MARK: Nudges

    func sendNudge(to recipientID: UUID) throws {
        guard recipientID == Self.barnabyID || recipientID == Self.ceriID else {
            throw SupabaseError.forbidden
        }
        if nudges.contains(where: {
            $0.senderID == Self.aliceID && $0.recipientID == recipientID
        }) {
            throw SupabaseError.rateLimited(hint: "Nudge already sent — wait for your friend to nudge back.")
        }

        // A reply acknowledges every incoming Nudge from this friend before sending it back.
        nudges.removeAll { $0.senderID == recipientID && $0.recipientID == Self.aliceID }
        nudges.append(DemoNudge(
            id: UUID(),
            senderID: Self.aliceID,
            recipientID: recipientID,
            createdAt: Date()
        ))
    }

    func receivedNudges() -> [NudgeDTO] {
        nudges
            .filter { $0.recipientID == Self.aliceID }
            .sorted { $0.createdAt > $1.createdAt }
            .map { item in
                NudgeDTO(
                    nudgeId: item.id,
                    senderId: item.senderID,
                    displayName: item.senderID == Self.barnabyID ? "Barnaby" : "Ceri",
                    avatarPath: nil,
                    createdAt: item.createdAt
                )
            }
    }

    // MARK: Feed

    func feedPage(before cursor: FeedCursor?, limit: Int) -> [FeedPostDTO] {
        let cursorKey: (Date, String)? = cursor.flatMap { c in
            SupabaseJSON.parseTimestamp(c.createdAt).map { ($0, c.postID.uuidString) }
        }
        return feedPosts
            .filter { $0.deletedAt == nil }
            .filter { post in
                guard let cursorKey else { return true }
                return (post.createdAt, post.id.uuidString) < cursorKey
            }
            .sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }
            .prefix(max(limit, 0))
            .map(feedPostDTO)
    }

    func comments(postID: UUID) -> [PostCommentDTO] {
        feedComments
            .filter { $0.postID == postID && $0.deletedAt == nil }
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
            .map { comment in
                PostCommentDTO(commentId: comment.id, authorId: comment.authorID,
                               displayName: feedDisplayName(for: comment.authorID),
                               avatarPath: feedAvatarPath(for: comment.authorID),
                               body: comment.body, createdAtRaw: comment.createdAtRaw,
                               mentionedUserIds: comment.mentionedUserIds)
            }
    }

    func toggleCheers(postID: UUID) -> ToggleCheersDTO {
        guard let index = feedPosts.firstIndex(where: { $0.id == postID }) else {
            return ToggleCheersDTO(cheered: false, cheersCount: 0)
        }
        feedPosts[index].viewerHasCheered.toggle()
        feedPosts[index].cheersCount = max(0, feedPosts[index].cheersCount + (feedPosts[index].viewerHasCheered ? 1 : -1))
        return ToggleCheersDTO(cheered: feedPosts[index].viewerHasCheered, cheersCount: feedPosts[index].cheersCount)
    }

    func createPost(body: String?, imagePath: String?, placeLabel: String?, pubID: UUID?) -> UUID {
        let createdAt = Date()
        let newPost = DemoPost(id: UUID(), authorID: Self.aliceID, body: body, imagePath: imagePath,
                               placeLabel: placeLabel, pubID: pubID, createdAt: createdAt,
                               createdAtRaw: Self.feedTimestampStyle.format(createdAt),
                               cheersCount: 0, viewerHasCheered: false, deletedAt: nil)
        feedPosts.insert(newPost, at: 0)
        return newPost.id
    }

    func deletePost(_ postID: UUID) {
        guard let index = feedPosts.firstIndex(where: { $0.id == postID }) else { return }
        feedPosts[index].deletedAt = Date()
    }

    func addComment(postID: UUID, body: String, mentions: [UUID]) -> UUID {
        let createdAt = Date()
        let comment = DemoComment(id: UUID(), postID: postID, authorID: Self.aliceID, body: body,
                                  createdAt: createdAt, createdAtRaw: Self.feedTimestampStyle.format(createdAt),
                                  mentionedUserIds: mentions, deletedAt: nil)
        feedComments.append(comment)
        return comment.id
    }

    func deleteComment(_ commentID: UUID) {
        guard let index = feedComments.firstIndex(where: { $0.id == commentID }) else { return }
        feedComments[index].deletedAt = Date()
    }

    private func feedDisplayName(for userID: UUID) -> String {
        switch userID {
        case Self.aliceID: return profile.displayName
        case Self.barnabyID: return "Barnaby"
        case Self.ceriID: return "Ceri"
        default: return "Mate"
        }
    }

    private func feedAvatarPath(for userID: UUID) -> String? {
        userID == Self.aliceID ? profile.avatarPath : nil
    }

    private func feedPostDTO(_ post: DemoPost) -> FeedPostDTO {
        FeedPostDTO(postId: post.id, authorId: post.authorID,
                    displayName: feedDisplayName(for: post.authorID),
                    avatarPath: feedAvatarPath(for: post.authorID),
                    body: post.body, imagePath: post.imagePath, placeLabel: post.placeLabel,
                    pubId: post.pubID, createdAtRaw: post.createdAtRaw,
                    cheersCount: post.cheersCount, viewerHasCheered: post.viewerHasCheered,
                    commentCount: feedComments.filter { $0.postID == post.id && $0.deletedAt == nil }.count)
    }

    // MARK: Leaderboard (uses the real tested builder)

    func leaderboard(period: LeaderboardPeriod, topCount: Int?) -> [LeaderboardRow] {
        let window = PeriodCalculator(profile: profile)
            .period(for: period, containing: Date(), session: session, now: Date())
        let activeEntries = entries.filter(\.countsTowardAlcoholTotals)
        func total(for userID: UUID) -> PintTotal? {
            PintCounter().total(of: activeEntries.filter { $0.userId == userID }, in: window)
        }

        let barnaby = LeaderboardParticipant(
            id: Self.barnabyID,
            displayName: "Barnaby",
            total: total(for: Self.barnabyID)
        )
        let ceri = LeaderboardParticipant(
            id: Self.ceriID,
            displayName: "Ceri",
            total: total(for: Self.ceriID)
        )
        let me = LeaderboardParticipant(
            id: Self.aliceID,
            displayName: profile.displayName,
            avatarPath: profile.avatarPath,
            isCurrentUser: true,
            total: total(for: Self.aliceID)
        )

        let builder = LeaderboardBuilder()
        if let topCount { return builder.preview([me, barnaby, ceri], topCount: topCount) }
        return builder.build([me, barnaby, ceri])
    }

    func friendBeerActivities() -> [FriendBeerActivity] {
        let users: [(UUID, String, String?)] = [
            (Self.aliceID, profile.displayName, profile.avatarPath),
            (Self.barnabyID, "Barnaby", nil),
            (Self.ceriID, "Ceri", nil),
        ]

        return users.map { userID, name, avatarPath in
            let logs = entries
                .filter { $0.isActive && $0.userId == userID }
                .sorted { $0.occurredAt > $1.occurredAt }
            let currentEntry = logs.first { $0.pubId != nil && Date().timeIntervalSince($0.occurredAt) <= 4 * 60 * 60 }
            let currentPub = currentEntry?.pubId.flatMap { pubs[$0] }
            let topPubs = Self.topPubs(from: logs, pubs: pubs)
            return FriendBeerActivity(
                userID: userID,
                displayName: name,
                avatarPath: avatarPath,
                currentPubID: currentPub?.id,
                currentPubName: currentPub?.name,
                currentPubAddress: currentPub?.formattedAddress,
                currentPubLatitude: currentPub?.latitude,
                currentPubLongitude: currentPub?.longitude,
                currentBeerName: currentEntry.flatMap { Self.beerName(in: $0.privateNote) },
                recentLogs: logs.map { entry in
                    FriendBeerLog(
                        id: entry.id,
                        beerName: Self.beerName(in: entry.privateNote) ?? "Mystery pint",
                        pubName: entry.pubId.flatMap { pubs[$0]?.name },
                        occurredAt: entry.occurredAt
                    )
                },
                topPubs: topPubs
            )
        }
    }

    private static func topPubs(from logs: [PintEntry], pubs: [UUID: Pub]) -> [FriendTopPub] {
        let grouped = Dictionary(grouping: logs.compactMap { entry -> (UUID, Date)? in
            guard let pubId = entry.pubId else { return nil }
            return (pubId, entry.occurredAt)
        }, by: \.0)

        return grouped.compactMap { pubId, visits -> FriendTopPub? in
            guard let pub = pubs[pubId], let lastVisit = visits.map(\.1).max() else { return nil }
            return FriendTopPub(
                id: pubId,
                name: pub.name,
                address: pub.formattedAddress,
                visitCount: visits.count,
                lastVisit: lastVisit
            )
        }
        .sorted {
            if $0.visitCount != $1.visitCount { return $0.visitCount > $1.visitCount }
            return $0.lastVisit > $1.lastVisit
        }
        .prefix(3)
        .map { $0 }
    }

    private static func beerName(in note: String?) -> String? {
        guard let note,
              let prefix = note.range(of: "[Beer: "),
              let closing = note[prefix.upperBound...].firstIndex(of: "]")
        else { return nil }
        return String(note[prefix.upperBound..<closing])
    }

    // MARK: Pubs

    func pubSearch() -> [PubSearchResult] {
        pubs.values.sorted { $0.name < $1.name }.map {
            PubSearchResult(name: $0.name, address: $0.formattedAddress, city: $0.city,
                            countryCode: $0.countryCode, latitude: $0.latitude, longitude: $0.longitude)
        }
    }

    func persist(_ result: PubSearchResult) -> Pub {
        if let pub = pubs.values.first(where: { $0.name == result.name }) { return pub }
        return Pub(id: UUID(),
            name: result.name, formattedAddress: result.address, city: result.city,
            countryCode: result.countryCode, latitude: result.latitude, longitude: result.longitude)
    }

    func newFriendToken() -> FriendToken { FriendToken.generate() }
}
