import XCTest
import CheekyPintCore
@testable import CheekyPint

/// App-target smoke tests. The exhaustive domain-logic suite lives in the CheekyPintCore
/// package (`swift test`); these confirm the app module links the core and wires a few pieces
/// together. Deeper feature tests belong beside their view models.
final class AppSmokeTests: XCTestCase {

    func testCoreIsLinkedAndCountingWorks() {
        // A representative CheekyPintCore call, proving the app links the tested core.
        let calendar = Profile(id: UUID(), displayName: "T", timezone: "Europe/London", locale: "en_GB").resolvedCalendar
        let period = PeriodCalculator(calendar: calendar).month(containing: Date())
        XCTAssertNotNil(period)
    }

    func testDeepLinkParserRoundTrips() {
        let parser = DeepLinkParser()
        let token = FriendToken.generate()
        XCTAssertEqual(parser.parse(parser.addFriendURL(token)), .addFriend(token))
    }

    func testRecommendedPrivacyDefaults() {
        let settings = PrivacySettings.recommendedDefault(userId: UUID())
        XCTAssertEqual(settings.cityVisibility, .private)
        XCTAssertEqual(settings.weeklyTotalVisibility, .friends)
    }
}
