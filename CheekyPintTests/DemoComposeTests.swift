import XCTest
@testable import CheekyPint

/// Demo mode's write half: a photo picked in the composer has to resolve to a real file (not a
/// bundle miss), and `pubID` must survive `DemoWorld.createPost` instead of being silently dropped.
final class DemoComposeTests: XCTestCase {

    private func makeProfileRepository() -> ProfileRepository {
        let config = AppConfig(environment: .development,
                               supabaseURL: URL(string: "https://example.supabase.co")!,
                               supabaseAnonKey: "k", universalHost: "example.invalid")
        return ProfileRepository(data: SupabaseData(config: config, auth: SupabaseAuth(config: config)))
    }

    func testWrittenDemoPostImageResolvesToAnExistingFile() throws {
        let repo = makeProfileRepository()
        let jpeg = try XCTUnwrap(UIImage(systemName: "photo")?.jpegData(compressionQuality: 0.8))
        let path = try repo.writeLocalPostImage(jpeg)
        XCTAssertTrue(path.hasPrefix("local-post-image/"), "got \(path)")
        let url = try XCTUnwrap(repo.postImageURL(for: path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "a composed demo photo must resolve to a real file, not a bundle miss")
    }

    func testSeededBundleDemoPostImageStillResolves() throws {
        let repo = makeProfileRepository()
        let url = try XCTUnwrap(repo.postImageURL(for: "local-post-image/demo-pint.png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "the seeded bundle asset must keep resolving after the fallback change")
    }

    func testDemoCreatePostKeepsThePubID() async throws {
        await DemoWorld.shared.activate(surname: "Alice")
        defer { Task { await DemoWorld.shared.deactivate() } }

        let world = DemoWorld.shared
        let pubID = UUID()
        let postID = await world.createPost(body: "Pub post", imagePath: nil,
                                            placeLabel: "The Kings Arms", pubID: pubID)
        let page = await world.feedPage(before: nil, limit: 50)
        let post = try XCTUnwrap(page.first { $0.postId == postID })
        XCTAssertEqual(post.pubId, pubID, "pubID must survive the demo write path")
        XCTAssertEqual(post.placeLabel, "The Kings Arms")
    }
}
