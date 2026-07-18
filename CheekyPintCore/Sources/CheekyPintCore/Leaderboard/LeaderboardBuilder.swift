import Foundation

/// Builds ordered, ranked leaderboard rows from participants. Pure and deterministic.
///
/// Ranking uses **standard competition ranking** (1, 2, 2, 4): equal totals share a rank
/// and the next rank skips accordingly. "Private" participants are never ranked and are
/// listed after everyone with a visible total. The treatment is deliberately neutral —
/// there are no medals or "winner" flags in the data model (master prompt §9).
public struct LeaderboardBuilder: Sendable {
    public let rule: PintCountingRule

    public init(rule: PintCountingRule = .default) {
        self.rule = rule
    }

    /// The full, ordered leaderboard.
    public func build(_ participants: [LeaderboardParticipant]) -> [LeaderboardRow] {
        let ranked = participants
            .filter { $0.total != nil }
            .sorted(by: Self.rankingOrder(rule: rule))

        let privateParticipants = participants
            .filter { $0.total == nil }
            .sorted { lhs, rhs in
                caseInsensitivePrecedes(lhs.displayName, rhs.displayName, lhs.id, rhs.id)
            }

        var rows: [LeaderboardRow] = []
        rows.reserveCapacity(participants.count)

        var previousValue: Double?
        var previousRank = 0
        for (index, participant) in ranked.enumerated() {
            let value = participant.total?.displayValue(for: rule) ?? 0
            let rank: Int
            if let previousValue, value == previousValue {
                rank = previousRank            // tie: share the previous rank
            } else {
                rank = index + 1               // competition ranking: position-based
            }
            previousValue = value
            previousRank = rank

            rows.append(
                LeaderboardRow(
                    id: participant.id,
                    rank: rank,
                    displayName: participant.displayName,
                    avatarPath: participant.avatarPath,
                    isCurrentUser: participant.isCurrentUser,
                    value: value,
                    isPrivate: false
                )
            )
        }

        for participant in privateParticipants {
            rows.append(
                LeaderboardRow(
                    id: participant.id,
                    rank: nil,
                    displayName: participant.displayName,
                    avatarPath: participant.avatarPath,
                    isCurrentUser: participant.isCurrentUser,
                    value: nil,
                    isPrivate: true
                )
            )
        }

        return rows
    }

    /// The compact home-screen preview: the top `topCount` rows, plus the current user
    /// appended if they fall outside the top set (master prompt §7 — "Include the current
    /// user even when they are not in the top three").
    public func preview(_ participants: [LeaderboardParticipant], topCount: Int = 3) -> [LeaderboardRow] {
        let full = build(participants)
        var preview = Array(full.prefix(topCount))

        if let currentUserRow = full.first(where: { $0.isCurrentUser }),
           !preview.contains(where: { $0.isCurrentUser }) {
            preview.append(currentUserRow)
        }
        return preview
    }

    // MARK: - Ordering

    private static func rankingOrder(
        rule: PintCountingRule
    ) -> (LeaderboardParticipant, LeaderboardParticipant) -> Bool {
        { lhs, rhs in
            let lhsValue = lhs.total?.displayValue(for: rule) ?? 0
            let rhsValue = rhs.total?.displayValue(for: rule) ?? 0
            if lhsValue != rhsValue { return lhsValue > rhsValue }         // higher total first
            return caseInsensitivePrecedes(lhs.displayName, rhs.displayName, lhs.id, rhs.id)
        }
    }
}

/// Deterministic tiebreak: case-insensitive name, then UUID string, so identical inputs
/// always produce identical ordering (important for stable UI and tests).
private func caseInsensitivePrecedes(_ lhsName: String, _ rhsName: String, _ lhsID: UUID, _ rhsID: UUID) -> Bool {
    let comparison = lhsName.localizedCaseInsensitiveCompare(rhsName)
    if comparison != .orderedSame { return comparison == .orderedAscending }
    return lhsID.uuidString < rhsID.uuidString
}
