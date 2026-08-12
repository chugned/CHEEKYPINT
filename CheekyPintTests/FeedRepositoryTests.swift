import XCTest
@testable import CheekyPint

/// The feed's paging correctness depends on round-tripping the server's `created_at` string
/// byte-for-byte. `feed_page` uses a compound `(created_at, id)` cursor precisely so tied
/// timestamps cannot skip rows; parsing the timestamp into a `Date` and re-serialising it loses
/// sub-second precision and lands the cursor between tied rows, silently dropping posts.
final class FeedRepositoryTests: XCTestCase {

    /// Replaces a vacuous predecessor that built `FeedCursor(createdAt: raw, …)` and then asserted
    /// `cursor.createdAt == raw` — `FeedCursor` is a plain struct with a memberwise init and two
    /// `let`s, so that only asserted the language stores an argument in a property, and there was no
    /// implementation it could fail against.
    ///
    /// The derivation that can actually break is `FeedPostDTO.cursor` / `PostCommentDTO.cursor`:
    /// both must build their cursor from `createdAtRaw`, never from the `createdAt: Date?` computed
    /// property sitting immediately above them in the same file. Routing it through `Date` is the
    /// tempting implementation and it silently loses sub-second precision, landing the cursor
    /// between tied rows and dropping posts — which is the whole reason `createdAtRaw` exists and
    /// carries a hand-written `CodingKeys` exception to do so.
    func testDTOCursorsCarryTheRawTimestampNotAReparsedDate() throws {
        // Six fractional digits and a non-UTC offset: an ISO8601 round trip through `Date` renders
        // this as at most three fractional digits, normalised to Z, so any reparse changes it.
        let raw = "2026-08-11T19:46:01.33476+02:00"
        let postID = UUID()
        let commentID = UUID()

        let post = FeedPostDTO(postId: postID, authorId: UUID(), displayName: "Barnaby",
                               avatarPath: nil, body: "first pint", imagePath: nil, placeLabel: nil,
                               pubId: nil, createdAtRaw: raw, cheersCount: 0, viewerHasCheered: false,
                               commentCount: 0)
        let comment = PostCommentDTO(commentId: commentID, authorId: UUID(), displayName: "Ceri",
                                     avatarPath: nil, body: "cheers", createdAtRaw: raw,
                                     mentionedUserIds: [])

        XCTAssertEqual(post.cursor, FeedCursor(createdAt: raw, postID: postID),
                       "a post's cursor must carry created_at verbatim and its own id")
        XCTAssertEqual(comment.cursor, FeedCursor(createdAt: raw, postID: commentID),
                       "a comment's cursor must carry created_at verbatim and the comment's id")

        // The flip made explicit: `createdAt` is the reparsed form, and it must not be what the
        // cursor is built from. Guard the fixture too — if `parseTimestamp` ever became lossless,
        // this test would stop distinguishing the two implementations.
        let reparsed = try XCTUnwrap(post.createdAt)
        let reserialised = ISO8601DateFormatter().string(from: reparsed)
        XCTAssertNotEqual(post.cursor.createdAt, reserialised,
                          "fixture bug: the raw string must differ from its reparsed form, or this " +
                          "test cannot tell a raw cursor from a Date-derived one")
    }

    func testCursorEncodesTheRawStringNotAReparsedDate() throws {
        let raw = "2026-08-11T19:46:01.33476+02:00"
        let id = UUID()
        let params = FeedPageParams(cursor: FeedCursor(createdAt: raw, postID: id), limit: 20)
        let json = try SupabaseJSON.encoder.encode(params)
        let text = String(decoding: json, as: UTF8.self)
        XCTAssertTrue(text.contains(raw), "encoded params lost the exact timestamp: \(text)")
        XCTAssertTrue(text.contains("p_before_id"), "cursor id must be sent as p_before_id: \(text)")
    }

    func testFirstPageSendsNullCursor() throws {
        let params = FeedPageParams(cursor: nil, limit: 20)
        let text = String(decoding: try SupabaseJSON.encoder.encode(params), as: UTF8.self)
        XCTAssertTrue(text.contains("\"p_before\":null"), "first page must send a null cursor: \(text)")
    }

    func testFeedPostDTODecodesSnakeCaseWithoutCodingKeys() throws {
        let json = Data("""
        {"post_id":"6B0F1E7E-6E4E-4B0E-9C3E-1E2A3B4C5D6E",
         "author_id":"7C1F2E8F-7F5F-4C1F-8D4F-2F3B4C5D6E7F",
         "display_name":"Barnaby","avatar_path":null,
         "body":"first pint","image_path":null,"place_label":"Prague","pub_id":null,
         "created_at":"2026-08-11T19:46:01.33476+02:00",
         "cheers_count":2,"viewer_has_cheered":true,"comment_count":1}
        """.utf8)
        let dto = try SupabaseJSON.decoder.decode(FeedPostDTO.self, from: json)
        XCTAssertEqual(dto.displayName, "Barnaby")
        XCTAssertEqual(dto.cheersCount, 2)
        XCTAssertTrue(dto.viewerHasCheered)
        XCTAssertEqual(dto.createdAtRaw, "2026-08-11T19:46:01.33476+02:00",
                       "the DTO must keep the raw timestamp for cursor use")
    }

    func testDemoModeReturnsSeededPostsWithoutNetwork() async throws {
        await DemoWorld.shared.activate(surname: "Alice")
        defer { Task { await DemoWorld.shared.deactivate() } }
        // A repository pointed at an unreachable host: if demo mode is honoured, no request is made.
        let config = AppConfig(environment: .development,
                               supabaseURL: URL(string: "https://unreachable.invalid")!,
                               supabaseAnonKey: "k", universalHost: "unreachable.invalid")
        let auth = SupabaseAuth(config: config)
        let repo = FeedRepository(data: SupabaseData(config: config, auth: auth))
        let posts = try await repo.page(before: nil, limit: 20)
        XCTAssertFalse(posts.isEmpty, "demo mode must seed a feed so the offline demo works")
    }

    func testPostImageURLUsesTheAuthenticatedObjectRoute() throws {
        let config = AppConfig(environment: .development,
                               supabaseURL: URL(string: "https://example.supabase.co")!,
                               supabaseAnonKey: "k", universalHost: "example.invalid")
        let repo = ProfileRepository(data: SupabaseData(config: config, auth: SupabaseAuth(config: config)))
        let url = repo.postImageURL(for: "abc/def.jpg")
        XCTAssertEqual(url?.absoluteString,
                       "https://example.supabase.co/storage/v1/object/post-images/abc/def.jpg",
                       "post photos are in a private bucket — the /object/public/ route returns 400")
        XCTAssertNil(repo.postImageURL(for: nil))
    }
}
