import XCTest
@testable import CheekyPintCore

final class LeaderboardBuilderTests: XCTestCase {
    private func participant(_ name: String, count: Int?, isCurrentUser: Bool = false) -> LeaderboardParticipant {
        LeaderboardParticipant(
            id: UUID(),
            displayName: name,
            isCurrentUser: isCurrentUser,
            total: count.map { PintTotal(recordedCount: $0, standardServings: Double($0)) }
        )
    }

    func testRanksByDescendingTotal() {
        let rows = LeaderboardBuilder().build([
            participant("Alice", count: 2),
            participant("Bob", count: 5),
            participant("Cara", count: 3)
        ])
        XCTAssertEqual(rows.map(\.displayName), ["Bob", "Cara", "Alice"])
        XCTAssertEqual(rows.map(\.rank), [1, 2, 3])
    }

    func testTiesShareRankWithCompetitionSkipping() {
        let rows = LeaderboardBuilder().build([
            participant("Bob", count: 5),
            participant("Cara", count: 5),
            participant("Alice", count: 1)
        ])
        // 5,5,1 → ranks 1,1,3 (competition ranking). Tie broken alphabetically for order.
        XCTAssertEqual(rows.map(\.displayName), ["Bob", "Cara", "Alice"])
        XCTAssertEqual(rows.map(\.rank), [1, 1, 3])
    }

    func testPrivateParticipantsAppearWithoutRankAfterRankedRows() {
        let rows = LeaderboardBuilder().build([
            participant("Bob", count: 5),
            participant("Zoe", count: nil),   // hid totals
            participant("Alice", count: 2)
        ])
        XCTAssertEqual(rows.map(\.displayName), ["Bob", "Alice", "Zoe"])
        XCTAssertEqual(rows[2].rank, nil)
        XCTAssertTrue(rows[2].isPrivate)
        XCTAssertNil(rows[2].value)
    }

    func testPreviewIncludesCurrentUserEvenWhenOutsideTopThree() {
        let me = participant("Me", count: 1, isCurrentUser: true)
        let rows = LeaderboardBuilder().preview([
            participant("Bob", count: 9),
            participant("Cara", count: 8),
            participant("Dan", count: 7),
            participant("Eve", count: 6),
            me
        ], topCount: 3)

        XCTAssertEqual(rows.count, 4, "top 3 plus the current user")
        XCTAssertEqual(rows.prefix(3).map(\.displayName), ["Bob", "Cara", "Dan"])
        XCTAssertTrue(rows.last!.isCurrentUser)
        XCTAssertEqual(rows.last!.displayName, "Me")
        XCTAssertEqual(rows.last!.rank, 5)
    }

    func testPreviewDoesNotDuplicateCurrentUserWhenAlreadyInTop() {
        let me = participant("Me", count: 100, isCurrentUser: true)
        let rows = LeaderboardBuilder().preview([
            me,
            participant("Bob", count: 9),
            participant("Cara", count: 8)
        ], topCount: 3)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.filter(\.isCurrentUser).count, 1)
    }
}
