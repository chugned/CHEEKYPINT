import XCTest
import CheekyPintCore
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
        XCTAssertEqual(path.split(separator: "/").first.map(String.init), uid.uuidString.lowercased(),
                       "server rejects a path whose first segment is not the caller's uid")
        XCTAssertFalse(path.contains(".."))
        XCTAssertTrue(path.hasSuffix(".jpg"))
        XCTAssertEqual(path.split(separator: "/").count, 2)
    }

    /// The regression this task's review caught: `UUID.uuidString` is always uppercase, but
    /// Postgres always renders `auth.uid()::text` lowercase, and every comparison against it
    /// (the `post-images` storage policies, `create_post`'s own ownership guard) is plain `text`
    /// equality — no `lower()`, not `citext`. A test written against bare `uid.uuidString` (as
    /// `testStoragePathIsInTheCallersOwnFolderWithNoTraversal` originally was) passes whether the
    /// folder segment is upper- or lower-case, so it could not have caught this; this test
    /// compares against the *lowercased* string explicitly, which the broken
    /// `"\(uid.uuidString)/..."` implementation fails.
    func testStoragePathFolderSegmentIsLowercaseToMatchAuthUidText() {
        let uid = UUID()
        let folder = String(ComposePostSheet.storagePath(uid: uid).split(separator: "/").first!)
        XCTAssertEqual(folder, uid.uuidString.lowercased(),
                       "auth.uid()::text is always lowercase and compared with plain `=`; " +
                       "an uppercase folder segment fails RLS and create_post's ownership check")
    }

    /// Same regression, same fix, in the avatar upload path — `ProfileRepository.uploadAvatar`
    /// had the identical defect against the identical kind of storage policy.
    func testAvatarStoragePathFolderSegmentIsLowercaseToMatchAuthUidText() {
        let uid = UUID()
        let folder = String(ProfileRepository.avatarStoragePath(uid: uid).split(separator: "/").first!)
        XCTAssertEqual(folder, uid.uuidString.lowercased(),
                       "auth.uid()::text is always lowercase and compared with plain `=`; " +
                       "an uppercase folder segment fails every avatars storage policy")
    }

    /// Behavioural replacement for the old tautological limits test (which asserted the two
    /// constants against themselves). A body one character past the limit must actually disable
    /// Post — the server truncates silently, and a user who wrote 501 characters should not
    /// discover the last character vanished after posting.
    func testBodyOverTheLimitBlocksSubmission() {
        let atLimit = String(repeating: "a", count: ComposePostSheet.bodyLimit)
        let overLimit = atLimit + "x"
        XCTAssertTrue(ComposePostSheet.canSubmit(body: atLimit, hasPhoto: false),
                      "exactly the limit must still be postable")
        XCTAssertFalse(ComposePostSheet.canSubmit(body: overLimit, hasPhoto: false),
                       "501 characters must block Post, not silently truncate on send")
    }

    /// Behavioural replacement for the place-label half of the same old test: an 81-character
    /// label must actually come back at 80 through the sanitizer call `ComposePostSheet` uses
    /// (Task 3 wires the input; the limit and the sanitize call are already load-bearing here).
    func testPlaceLabelOverTheLimitIsClampedTo80() {
        let sanitizer = ProfileTextSanitizer()
        let overLimit = String(repeating: "b", count: ComposePostSheet.placeLabelLimit + 1)
        let clamped = sanitizer.sanitize(overLimit, allowNewlines: false, maxLength: ComposePostSheet.placeLabelLimit)
        XCTAssertEqual(clamped.count, ComposePostSheet.placeLabelLimit,
                       "an 81-character place label must be clamped to 80, mirroring create_post's left(v_label, 80)")
    }
}
