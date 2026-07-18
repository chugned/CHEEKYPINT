import XCTest
@testable import CheekyPintCore

final class VisibilityResolverTests: XCTestCase {
    private let resolver = VisibilityResolver()
    private let settings = PrivacySettings.recommendedDefault(userId: UUID())

    func testBlockOverridesEverything() {
        // Even a normally-visible field is hidden for a blocked relationship.
        for field: ProfileField in [.displayName, .avatar, .city, .total(.week), .favouritePubs] {
            XCTAssertEqual(resolver.decision(for: field, relationship: .blocked, settings: settings), .hidden)
        }
        XCTAssertFalse(resolver.canViewProfile(relationship: .blocked, profileVisibility: .friends))
    }

    func testCurrentUserSeesEverything() {
        for field: ProfileField in [.displayName, .city, .total(.year), .favouritePubs] {
            XCTAssertEqual(resolver.decision(for: field, relationship: .current, settings: settings), .visible)
        }
    }

    func testFriendSeesFieldsSharedWithFriends() {
        // Recommended defaults: totals → friends, city → private, favourite pubs → private.
        XCTAssertEqual(resolver.decision(for: .total(.week), relationship: .friend, settings: settings), .visible)
        XCTAssertEqual(resolver.decision(for: .displayName, relationship: .friend, settings: settings), .visible)
    }

    func testFriendGetsPrivatePlaceholderForHiddenTotalsButHiddenForOtherFields() {
        var custom = settings
        custom.weeklyTotalVisibility = .private
        // A hidden total shows as "Private", not a fake zero.
        XCTAssertEqual(resolver.decision(for: .total(.week), relationship: .friend, settings: custom), .privatePlaceholder)
        // A hidden non-total field simply disappears.
        XCTAssertEqual(resolver.decision(for: .city, relationship: .friend, settings: custom), .hidden)
        XCTAssertEqual(resolver.decision(for: .favouritePubs, relationship: .friend, settings: custom), .hidden)
    }

    func testPendingRequestSeesOnlyNameAndAvatar() {
        XCTAssertEqual(resolver.decision(for: .displayName, relationship: .pendingRequest, settings: settings), .visible)
        XCTAssertEqual(resolver.decision(for: .avatar, relationship: .pendingRequest, settings: settings), .visible)
        XCTAssertEqual(resolver.decision(for: .city, relationship: .pendingRequest, settings: settings), .hidden)
        XCTAssertEqual(resolver.decision(for: .total(.week), relationship: .pendingRequest, settings: settings), .hidden)
        XCTAssertFalse(resolver.canViewProfile(relationship: .pendingRequest, profileVisibility: .friends))
    }

    func testStrangerSeesNothing() {
        XCTAssertEqual(resolver.decision(for: .displayName, relationship: .stranger, settings: settings), .hidden)
        XCTAssertFalse(resolver.canViewProfile(relationship: .stranger, profileVisibility: .friends))
    }

    func testProfileNotViewableWhenProfileVisibilityPrivateEvenForFriend() {
        XCTAssertFalse(resolver.canViewProfile(relationship: .friend, profileVisibility: .private))
        XCTAssertTrue(resolver.canViewProfile(relationship: .friend, profileVisibility: .friends))
    }
}
