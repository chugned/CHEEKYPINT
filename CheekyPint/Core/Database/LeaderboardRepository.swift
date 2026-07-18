import Foundation
import CoreLocation
import CheekyPintCore

/// Fetches friend standings. The calendar-aware window is computed locally by the tested
/// `PeriodCalculator`, sent to `get_friend_leaderboard`, and the returned totals are ranked by
/// the tested `LeaderboardBuilder`. The server enforces privacy + blocks; the client never sees
/// raw friend entries (master prompt §9, §14).
struct LeaderboardRepository: Sendable {
    let data: SupabaseData

    private func participants(
        period: LeaderboardPeriod, profile: Profile, now: Date, session: PubSession?
    ) async throws -> [LeaderboardParticipant] {
        let calculator = PeriodCalculator(profile: profile)
        guard let window = calculator.period(for: period, containing: now, session: session, now: now) else {
            return [] // e.g. "Now" selected but no active session
        }
        let params = LeaderboardParams(
            pPeriodStart: window.start,
            pPeriodEnd: window.end,
            pPeriodKind: period.rawValue,
            pSessionId: session?.id
        )
        let rows: [LeaderboardRowDTO] = try await data.rpc("get_friend_leaderboard", params: params)
        return rows.map { row in
            LeaderboardParticipant(
                id: row.userId,
                displayName: row.displayName,
                avatarPath: row.avatarPath,
                isCurrentUser: row.isCurrentUser,
                total: row.isPrivate ? nil : PintTotal(recordedCount: row.recordedCount, standardServings: Double(row.recordedCount))
            )
        }
    }

    func fullLeaderboard(period: LeaderboardPeriod, profile: Profile, now: Date = Date(), session: PubSession?) async throws -> [LeaderboardRow] {
        if await DemoWorld.shared.isActive { return await DemoWorld.shared.leaderboard(period: period, topCount: nil) }
        return LeaderboardBuilder().build(try await participants(period: period, profile: profile, now: now, session: session))
    }

    func preview(period: LeaderboardPeriod, profile: Profile, now: Date = Date(), session: PubSession?, topCount: Int = 3) async throws -> [LeaderboardRow] {
        if await DemoWorld.shared.isActive { return await DemoWorld.shared.leaderboard(period: period, topCount: topCount) }
        return LeaderboardBuilder().preview(try await participants(period: period, profile: profile, now: now, session: session), topCount: topCount)
    }
}

struct FriendBeerLog: Identifiable, Sendable, Hashable {
    let id: UUID
    let beerName: String
    let pubName: String?
    let occurredAt: Date
}

struct FriendTopPub: Identifiable, Sendable, Hashable {
    let id: UUID
    let name: String
    let address: String?
    let visitCount: Int
    let lastVisit: Date
}

struct FriendBeerActivity: Identifiable, Sendable, Hashable {
    let userID: UUID
    let displayName: String
    let avatarPath: String?
    let currentPubID: UUID?
    let currentPubName: String?
    let currentPubAddress: String?
    let currentPubLatitude: Double?
    let currentPubLongitude: Double?
    let currentBeerName: String?
    let recentLogs: [FriendBeerLog]
    let topPubs: [FriendTopPub]

    var id: UUID { userID }

    var currentCoordinate: CLLocationCoordinate2D? {
        guard let currentPubLatitude, let currentPubLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: currentPubLatitude, longitude: currentPubLongitude)
    }

    var nowText: String {
        switch (currentBeerName, currentPubName) {
        case let (beer?, pub?): return "\(beer) at \(pub)"
        case let (beer?, nil): return "\(beer), pub unknown"
        case let (nil, pub?): return "At \(pub)"
        default: return "Not checked into a pub right now"
        }
    }
}

struct FriendActivityRepository: Sendable {
    let data: SupabaseData

    func beerActivities() async throws -> [FriendBeerActivity] {
        if await DemoWorld.shared.isActive { return await DemoWorld.shared.friendBeerActivities() }
        // Server mode currently exposes privacy-resolved totals only. Friend-circle/demo mode
        // carries the richer beer/pub activity used by this private group build.
        return []
    }
}
