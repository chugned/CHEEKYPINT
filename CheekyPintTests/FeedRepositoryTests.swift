import XCTest
@testable import CheekyPint

/// The feed's paging correctness depends on round-tripping the server's `created_at` string
/// byte-for-byte. `feed_page` uses a compound `(created_at, id)` cursor precisely so tied
/// timestamps cannot skip rows; parsing the timestamp into a `Date` and re-serialising it loses
/// sub-second precision and lands the cursor between tied rows, silently dropping posts.
final class FeedRepositoryTests: XCTestCase {

    func testCursorPreservesTheRawTimestampString() throws {
        let raw = "2026-08-11T19:46:01.33476+02:00"
        let cursor = FeedCursor(createdAt: raw, postID: UUID())
        XCTAssertEqual(cursor.createdAt, raw, "the cursor must not reformat the server's timestamp")
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
