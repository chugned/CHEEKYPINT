import Foundation
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
