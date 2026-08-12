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
    ///
    /// **500 is a literal here, and the input is built from that literal, not from
    /// `ComposePostSheet.bodyLimit`.** Deriving both sides from the constant made this test pass
    /// for any value of it — including 5000, which would desynchronise the client from
    /// `create_post`'s `left(v_body, 500)` and reintroduce silent truncation. The constant exists
    /// only to mirror that SQL, so the SQL's number is what this test has to pin.
    func testBodyOverTheLimitBlocksSubmission() {
        XCTAssertEqual(ComposePostSheet.bodyLimit, 500,
                       "must mirror create_post's left(v_body, 500) — a literal, so changing the " +
                       "constant fails here rather than silently redefining the limit")

        let atLimit = String(repeating: "a", count: 500)
        XCTAssertTrue(ComposePostSheet.canSubmit(body: atLimit, hasPhoto: false),
                      "exactly 500 must still be postable")
        XCTAssertFalse(ComposePostSheet.canSubmit(body: atLimit + "x", hasPhoto: false),
                       "501 characters must block Post, not silently truncate on send")
    }

    /// The place-label limit is pinned behaviourally by `PlacePickerTests`
    /// `testLabelIsClampedToTheServerLimit`, which drives `PlacePickerSheet.freeTextPlace` — the
    /// only consumer of `placeLabelLimit` — with a 200-character label and requires 80 back. The
    /// literal here is the other half of that: it pins the constant to the SQL it mirrors, whereas
    /// the removed `testPlaceLabelOverTheLimitIsClampedTo80` called `ProfileTextSanitizer` directly
    /// with a limit taken from the constant, so it exercised no `ComposePostSheet` code at all and
    /// stayed green for any value of the constant.
    func testPlaceLabelLimitMirrorsTheServerClamp() {
        XCTAssertEqual(ComposePostSheet.placeLabelLimit, 80,
                       "must mirror create_post's left(v_label, 80)")
    }

    /// `canSubmit` gates on the code-point length the server will measure, not the grapheme-cluster
    /// count `String.count` reports. 300 NFD-decomposed characters — what pasting accented text
    /// from macOS produces — is 600 code points, so `left(v_body, 500)` would cut 100 of them; the
    /// counter said "300/500" and Post was enabled. Both must now refuse.
    func testCounterAndGateMeasureCodePointsSoNFDTextCannotOverrunTheServerLimit() {
        let nfd = String(repeating: "a\u{0308}", count: 300)
        XCTAssertEqual(nfd.count, 300, "fixture: 300 user-visible characters")

        XCTAssertEqual(ComposePostSheet.bodyLength(of: nfd), 600,
                       "the counter must show the stored code-point length, not the 300 typed")
        XCTAssertFalse(ComposePostSheet.canSubmit(body: nfd, hasPhoto: false),
                       "600 code points exceeds 500, so Post must be blocked rather than letting " +
                       "the server drop 100 of them")

        // The boundary in the server's own unit: 250 clusters is exactly 500 code points and must
        // still be postable, so the gate is not merely rejecting all multi-scalar text.
        XCTAssertTrue(ComposePostSheet.canSubmit(body: String(repeating: "a\u{0308}", count: 250),
                                                 hasPhoto: false),
                      "exactly 500 code points must still be postable")
    }
}
