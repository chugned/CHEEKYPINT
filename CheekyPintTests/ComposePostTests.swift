import XCTest
@testable import CheekyPint

/// The composer's client-side gate: mirrors `create_post`'s "needs a photo or words" guard and
/// the `<uid>/<uuid>.jpg` storage-path shape it enforces server-side, so the user sees a local
/// message instead of a round trip.
final class ComposePostTests: XCTestCase {
    func testPostIsRejectedLocallyWhenEmpty() {
        XCTAssertFalse(ComposePostSheet.canPost(body: "", hasPhoto: false))
        XCTAssertFalse(ComposePostSheet.canPost(body: "   \n\t ", hasPhoto: false),
                       "whitespace-only is what the server calls empty")
        XCTAssertTrue(ComposePostSheet.canPost(body: "", hasPhoto: true))
        XCTAssertTrue(ComposePostSheet.canPost(body: "Cheers", hasPhoto: false))
    }

    func testStoragePathIsInTheCallersOwnFolderWithNoTraversal() throws {
        let uid = UUID()
        let path = ComposePostSheet.storagePath(uid: uid)
        XCTAssertEqual(path.split(separator: "/").first.map(String.init), uid.uuidString,
                       "server rejects a path whose first segment is not the caller's uid")
        XCTAssertFalse(path.contains(".."))
        XCTAssertTrue(path.hasSuffix(".jpg"))
        XCTAssertEqual(path.split(separator: "/").count, 2)
    }

    func testBodyAndLabelAreClampedToTheServerLimits() {
        XCTAssertEqual(ComposePostSheet.bodyLimit, 500)
        XCTAssertEqual(ComposePostSheet.placeLabelLimit, 80)
    }
}
