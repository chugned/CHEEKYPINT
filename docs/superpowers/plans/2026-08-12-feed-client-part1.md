# Feed Client, Part 1 — Data Layer and a Visible Feed

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Tasks:** 3. Task 3 ends with a Feed tab a user can actually see and scroll.

**Goal:** Put the friends-only feed on screen. The backend is complete, tested and reviewed but no screen talks to it — a user can currently do none of what the feature promises.

**Architecture:** Three layers, bottom-up. Task 1 adds the DTOs and `FeedRepository` that wrap the shipped RPCs, plus demo-mode support so the app's offline demo keeps working. Task 2 teaches `ImageLoader` to authenticate, because post photos now live in a private bucket and the old public-URL path returns 400. Task 3 adds `FeedViewModel`, `FeedView`, `FeedPostCard` and a fourth tab — read-only: scroll, and toggle Cheers. Composing, commenting, reporting and export are Part 2.

**Tech Stack:** SwiftUI (iOS 17+), Swift 6 strict concurrency, `@Observable` view models, Supabase RPCs + Storage.

## Global Constraints

- `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` in **every** shell invocation. `xcode-select` points at the CLT, so a bare `xcodebuild`/`swift test` fails or cannot find XCTest.
- Run `xcodegen generate` after adding or deleting any file, or Xcode will not see it.
- Swift language mode 6, `SWIFT_STRICT_CONCURRENCY = complete`. New types must be `Sendable`-clean; view models are `@MainActor @Observable final class`.
- **No new third-party dependencies.** The app ships with zero and that is deliberate.
- **Every repository method must branch on demo mode**, exactly as `FriendsRepository` does: `if await DemoWorld.shared.isActive { … return }` before touching the network. The welcome screen's "Explore in demo mode" and the `-uiTestDemo` launch argument both depend on it; a feed that throws in demo mode breaks the UI tests and the only database-free way to see the app.
- DTOs follow the existing style: `struct XDTO: Decodable, Sendable` (add `Identifiable` when a view iterates them), camelCase properties. `JSONCoding.swift:9` sets `.convertFromSnakeCase`, so **never** write `CodingKeys` — no neighbouring DTO has them.
- Params structs follow `RPCContracts.swift`: `struct XParams: Encodable, Sendable` with `pFoo` properties, encoded to `p_foo` by `.convertToSnakeCase`.
- Match the surrounding view conventions: `Theme.Palette` / `Theme.Typography` / `Theme.Spacing` for all styling, `coasterCard()` and `pubBackground()` where they fit, `RemoteAvatar` for avatars, `PintButtonStyle` / `ScaleButtonStyle` for buttons. Do not introduce raw colours, fonts or spacing values.
- Accessibility is not optional here: every control needs a label, tap targets respect `Theme.minTapTarget`, and animations honour `@Environment(\.accessibilityReduceMotion)` as `PintButtonStyle` does.
- Existing suites must stay green after every task: **87 SQL assertions** (`./supabase/tests/run_local_pg.sh`), **54 `CheekyPintCore`** (`swift test`), **12 app tests** (`-only-testing:CheekyPintTests`).
- Work on branch `feat/feed-client`, cut from `feat/datenschutz-hardening`. Commit per task. Never touch `master`.
- Do **not** modify any file under `supabase/` — the backend is settled. If you believe an RPC is wrong, stop and report BLOCKED with the reason rather than changing it.

## Backend interfaces this plan consumes

Shipped, tested, and fixed. Match these signatures exactly.

| RPC | Arguments | Returns |
|---|---|---|
| `feed_page` | `p_before timestamptz`, `p_before_id uuid`, `p_limit int` | rows: `post_id, author_id, display_name, avatar_path, body, image_path, place_label, pub_id, created_at, cheers_count, viewer_has_cheered, comment_count` |
| `toggle_post_cheers` | `p_post_id uuid` | jsonb `{cheered: bool, cheers_count: int}` |
| `create_post` | `p_body text`, `p_image_path text`, `p_place_label text`, `p_pub_id uuid` | jsonb `{post_id: uuid}` |
| `delete_post` | `p_post_id uuid` | void |
| `post_comments_page` | `p_post_id uuid`, `p_before timestamptz`, `p_before_id uuid`, `p_limit int` | rows: `comment_id, author_id, display_name, avatar_path, body, created_at, mentioned_user_ids` |
| `add_comment` | `p_post_id uuid`, `p_body text`, `p_mentions uuid[]` | jsonb `{comment_id: uuid}` |
| `delete_comment` | `p_comment_id uuid` | void |
| `report_post` | `p_post_id uuid`, `p_category report_category`, `p_details text` | jsonb `{report_id, status}` |
| `report_comment` | `p_comment_id uuid`, `p_category report_category`, `p_details text` | jsonb `{report_id, status}` |
| `export_my_data` | none | jsonb (14 collections) |

**Cursor precision matters.** `feed_page`'s compound `(created_at, id)` cursor exists specifically so tied timestamps cannot skip rows. If the client parses `created_at` into a Swift `Date` and re-serialises it, microseconds are lost and the cursor lands between tied rows. **Round-trip the raw string untouched** — see Task 1, Step 3.

**Errors you must map:** `28000` not authenticated, `P0002` not available/not found, `22023` invalid argument, `P0001` rate limited. Rate limits in play: `post_create` 20/hr, `post_comment` 60/hr, `cheers_toggle` 120/hr, `report` 20/hr, `data_export` 5/24h. Oversized `image_path` or a bad `pub_id` can surface a raw `23514`/`23503`.

---

## File Structure

| File | Responsibility |
|---|---|
| `CheekyPint/Core/Database/RPCContracts.swift` | Add `FeedPostDTO`, `PostCommentDTO`, `ToggleCheersDTO`, `CreatedPostDTO` and their params structs |
| `CheekyPint/Core/Database/FeedRepository.swift` | Wraps the feed RPCs; demo-mode aware |
| `CheekyPint/Core/Demo/DemoWorld.swift` | Seeded in-memory feed so demo mode works |
| `CheekyPint/App/AppContainer.swift` | Expose `feed` alongside the other repositories |
| `CheekyPint/Core/Networking/ImageLoader.swift` | Send the caller's bearer token; drop the stale Wikimedia rationale |
| `CheekyPint/Core/Database/ProfileRepository.swift` | Add `postImageURL(for:)` mirroring `avatarURL(for:)` |
| `CheekyPint/Features/Feed/FeedViewModel.swift` | Paging, optimistic Cheers, error state |
| `CheekyPint/Features/Feed/FeedView.swift` | The tab: list, pull-to-refresh, empty and error states |
| `CheekyPint/Features/Feed/FeedPostCard.swift` | One post |
| `CheekyPint/Features/Home/MainTabView.swift` | Fourth tab |
| `CheekyPintTests/FeedRepositoryTests.swift` | Cursor round-trip + demo-mode routing |

---

### Task 1: DTOs, `FeedRepository`, and demo-mode support

**Files:**
- Modify: `CheekyPint/Core/Database/RPCContracts.swift`
- Create: `CheekyPint/Core/Database/FeedRepository.swift`
- Modify: `CheekyPint/Core/Demo/DemoWorld.swift`
- Modify: `CheekyPint/App/AppContainer.swift`
- Create: `CheekyPintTests/FeedRepositoryTests.swift`

**Interfaces:**
- Consumes: `SupabaseData.rpc` / `.rpcVoid`, `DemoWorld.shared`.
- Produces: `FeedPostDTO`, `PostCommentDTO`, `ToggleCheersDTO`, `CreatedPostDTO`; `FeedRepository` with `page(before:limit:)`, `toggleCheers(postID:)`, `createPost(body:imagePath:placeLabel:pubID:)`, `deletePost(_:)`, `comments(postID:before:limit:)`, `addComment(postID:body:mentions:)`, `deleteComment(_:)`, `reportPost(_:category:details:)`, `reportComment(_:category:details:)`, `exportMyData()`; `FeedCursor`; `AppContainer.feed`.

- [ ] **Step 1: Write the failing test**

Create `CheekyPintTests/FeedRepositoryTests.swift`:

```swift
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
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd ~/Projects/cheekypint && xcodegen generate
xcodebuild test -project CheekyPint.xcodeproj -scheme CheekyPint \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build \
  -only-testing:CheekyPintTests/FeedRepositoryTests 2>&1 | tail -20
```

Expected: FAIL to compile — `cannot find 'FeedCursor' in scope`.

- [ ] **Step 3: Add the DTOs and params to `RPCContracts.swift`**

The critical detail is `createdAtRaw`. Decode the timestamp as a `String`, not a `Date`, and expose a parsed `Date` separately for display. That keeps the cursor byte-exact while still giving views something to format.

```swift
// MARK: Feed

/// A cursor into the feed. Both halves travel together: `feed_page` orders by
/// `(created_at, id)` so tied timestamps cannot skip rows, and sending only the timestamp
/// silently reintroduces that bug.
struct FeedCursor: Sendable, Equatable {
    let createdAt: String
    let postID: UUID
}

struct FeedPageParams: Encodable, Sendable {
    let pBefore: String?
    let pBeforeId: UUID?
    let pLimit: Int

    init(cursor: FeedCursor?, limit: Int) {
        self.pBefore = cursor?.createdAt
        self.pBeforeId = cursor?.postID
        self.pLimit = limit
    }
}

struct PostIDParams: Encodable, Sendable { let pPostId: UUID }
struct CommentIDParams: Encodable, Sendable { let pCommentId: UUID }

struct CreatePostParams: Encodable, Sendable {
    let pBody: String?
    let pImagePath: String?
    let pPlaceLabel: String?
    let pPubId: UUID?
}

struct CommentsPageParams: Encodable, Sendable {
    let pPostId: UUID
    let pBefore: String?
    let pBeforeId: UUID?
    let pLimit: Int
}

struct AddCommentParams: Encodable, Sendable {
    let pPostId: UUID
    let pBody: String
    let pMentions: [UUID]
}

struct ReportPostParams: Encodable, Sendable {
    let pPostId: UUID
    let pCategory: String
    let pDetails: String?
}

struct ReportCommentParams: Encodable, Sendable {
    let pCommentId: UUID
    let pCategory: String
    let pDetails: String?
}

/// One row of the friends-only feed.
///
/// `createdAtRaw` is deliberately a `String`: it is the cursor's first half and must survive a
/// round trip byte-for-byte. `createdAt` is the parsed form, for display only.
struct FeedPostDTO: Decodable, Sendable, Identifiable {
    let postId: UUID
    let authorId: UUID
    let displayName: String
    let avatarPath: String?
    let body: String?
    let imagePath: String?
    let placeLabel: String?
    let pubId: UUID?
    let createdAtRaw: String
    let cheersCount: Int
    let viewerHasCheered: Bool
    let commentCount: Int

    var id: UUID { postId }
    var createdAt: Date? { SupabaseJSON.parseTimestamp(createdAtRaw) }
    var cursor: FeedCursor { FeedCursor(createdAt: createdAtRaw, postID: postId) }

    private enum CodingKeys: String, CodingKey {
        case postId, authorId, displayName, avatarPath, body, imagePath
        case placeLabel, pubId, cheersCount, viewerHasCheered, commentCount
        case createdAtRaw = "createdAt"
    }
}

struct PostCommentDTO: Decodable, Sendable, Identifiable {
    let commentId: UUID
    let authorId: UUID
    let displayName: String
    let avatarPath: String?
    let body: String
    let createdAtRaw: String
    let mentionedUserIds: [UUID]

    var id: UUID { commentId }
    var createdAt: Date? { SupabaseJSON.parseTimestamp(createdAtRaw) }
    var cursor: FeedCursor { FeedCursor(createdAt: createdAtRaw, postID: commentId) }

    private enum CodingKeys: String, CodingKey {
        case commentId, authorId, displayName, avatarPath, body, mentionedUserIds
        case createdAtRaw = "createdAt"
    }
}

struct ToggleCheersDTO: Decodable, Sendable {
    let cheered: Bool
    let cheersCount: Int
}

struct CreatedPostDTO: Decodable, Sendable { let postId: UUID }
struct CreatedCommentDTO: Decodable, Sendable { let commentId: UUID }
```

**Note the one deliberate exception to the no-`CodingKeys` rule.** These two DTOs need it *only* to map the server's `created_at` onto a differently-named property, because the whole point is to keep the string rather than let the decoder turn it into a `Date`. `.convertFromSnakeCase` turns `created_at` into `createdAt`, so `createdAtRaw` must be spelled out. Every other property still relies on the automatic conversion — do not add keys for them.

Add the timestamp parser to `JSONCoding.swift`, next to the existing coders:

```swift
    /// Parses a Postgres `timestamptz` for display. Reuses the two formatters this enum already
    /// defines for its custom `dateDecodingStrategy` — Postgres trims trailing fractional zeros,
    /// so the sub-second digit count varies per row and one formatter cannot cover both forms.
    /// Display only: the cursor always carries the raw string.
    static func parseTimestamp(_ raw: String) -> Date? {
        iso8601.date(from: raw) ?? iso8601NoFraction.date(from: raw)
    }
```

`iso8601` and `iso8601NoFraction` already exist in this enum (used by `decoder`'s custom strategy) —
reuse them rather than introducing a third date-parsing path. Confirm their exact names when you
read the file.

- [ ] **Step 4: Create `FeedRepository`**

```swift
import Foundation
import CheekyPintCore

/// The friends-only feed. Every read and write goes through a `security definer` RPC that
/// re-derives friendship and block state per call — the client never reads post rows directly,
/// and holding a post id is never sufficient authority.
struct FeedRepository: Sendable {
    let data: SupabaseData

    // MARK: Reading

    func page(before cursor: FeedCursor?, limit: Int = 20) async throws -> [FeedPostDTO] {
        if await DemoWorld.shared.isActive { return await DemoWorld.shared.feedPage(before: cursor, limit: limit) }
        return try await data.rpc("feed_page", params: FeedPageParams(cursor: cursor, limit: limit))
    }

    func comments(postID: UUID, before cursor: FeedCursor?, limit: Int = 30) async throws -> [PostCommentDTO] {
        if await DemoWorld.shared.isActive { return await DemoWorld.shared.comments(postID: postID) }
        return try await data.rpc("post_comments_page", params: CommentsPageParams(
            pPostId: postID, pBefore: cursor?.createdAt, pBeforeId: cursor?.postID, pLimit: limit))
    }

    // MARK: Writing

    func toggleCheers(postID: UUID) async throws -> ToggleCheersDTO {
        if await DemoWorld.shared.isActive { return await DemoWorld.shared.toggleCheers(postID: postID) }
        return try await data.rpc("toggle_post_cheers", params: PostIDParams(pPostId: postID))
    }

    @discardableResult
    func createPost(body: String?, imagePath: String?, placeLabel: String?, pubID: UUID?) async throws -> UUID {
        if await DemoWorld.shared.isActive {
            return await DemoWorld.shared.createPost(body: body, imagePath: imagePath, placeLabel: placeLabel)
        }
        let created: CreatedPostDTO = try await data.rpc("create_post", params: CreatePostParams(
            pBody: body, pImagePath: imagePath, pPlaceLabel: placeLabel, pPubId: pubID))
        return created.postId
    }

    func deletePost(_ postID: UUID) async throws {
        if await DemoWorld.shared.isActive { await DemoWorld.shared.deletePost(postID); return }
        try await data.rpcVoid("delete_post", params: PostIDParams(pPostId: postID))
    }

    @discardableResult
    func addComment(postID: UUID, body: String, mentions: [UUID]) async throws -> UUID {
        if await DemoWorld.shared.isActive {
            return await DemoWorld.shared.addComment(postID: postID, body: body, mentions: mentions)
        }
        let created: CreatedCommentDTO = try await data.rpc("add_comment", params: AddCommentParams(
            pPostId: postID, pBody: body, pMentions: mentions))
        return created.commentId
    }

    func deleteComment(_ commentID: UUID) async throws {
        if await DemoWorld.shared.isActive { await DemoWorld.shared.deleteComment(commentID); return }
        try await data.rpcVoid("delete_comment", params: CommentIDParams(pCommentId: commentID))
    }

    // MARK: Moderation and data rights

    func reportPost(_ postID: UUID, category: String, details: String?) async throws {
        if await DemoWorld.shared.isActive { return }
        _ = try await data.rpc("report_post", params: ReportPostParams(
            pPostId: postID, pCategory: category, pDetails: details)) as ReportAckDTO
    }

    func reportComment(_ commentID: UUID, category: String, details: String?) async throws {
        if await DemoWorld.shared.isActive { return }
        _ = try await data.rpc("report_comment", params: ReportCommentParams(
            pCommentId: commentID, pCategory: category, pDetails: details)) as ReportAckDTO
    }

    /// DSGVO Art. 15/20 self-service export. Returned as raw bytes so the caller can hand the
    /// user the exact document the server produced, without a lossy re-encode.
    func exportMyData() async throws -> Data {
        if await DemoWorld.shared.isActive { return Data("{\"demo\":true}".utf8) }
        return try await data.rpcRaw("export_my_data")
    }
}
```

`ReportAckDTO` may already exist for `report_user` — check `RPCContracts.swift` and reuse it; if not, add `struct ReportAckDTO: Decodable, Sendable { let reportId: UUID; let status: String }`.

`data.rpcRaw(_:)` probably does not exist. Read `SupabaseData.swift` and add the smallest helper that performs the RPC and returns the response body unparsed, following the shape of the existing `rpc`/`rpcVoid`. Say in your report what you added.

- [ ] **Step 5: Add demo-mode feed state to `DemoWorld`**

Follow the file's existing style: private state, seeded in `activate`, one method per repository call. Seed **three** posts so paging and ordering are visible: one from Alice with a body and a place label, one from Barnaby with a body, one from Ceri. Give one of them two Cheers and one comment so the counts are not all zero. `viewerHasCheered` should be true for exactly one, so the toggle's both directions are exercisable by hand.

Implement `feedPage(before:limit:)` honouring the cursor (filter to strictly-older `(createdAt, id)` pairs and cap at `limit`), `comments(postID:)`, `toggleCheers(postID:)` flipping state and returning the new count, `createPost`, `deletePost`, `addComment`, `deleteComment`.

Demo posts need a stable `createdAtRaw`. Generate it once at seed time with `Date.ISO8601FormatStyle(includingFractionalSeconds: true)` so the cursor round-trip works identically to production.

- [ ] **Step 6: Expose it on `AppContainer`**

```swift
    var feed: FeedRepository { FeedRepository(data: data) }
```

Place it with the other repository accessors.

- [ ] **Step 7: Run the tests**

```bash
xcodebuild test -project CheekyPint.xcodeproj -scheme CheekyPint \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build \
  -only-testing:CheekyPintTests 2>&1 | grep -E "Executed|error:"
```

Expected: all pass — 12 existing plus 5 new. Then confirm `CheekyPintCore` is still 54 and the SQL suite still 87.

- [ ] **Step 8: Commit**

```bash
git add CheekyPint/Core/Database/RPCContracts.swift CheekyPint/Core/Database/FeedRepository.swift \
        CheekyPint/Core/Networking/JSONCoding.swift CheekyPint/Core/Networking/SupabaseData.swift \
        CheekyPint/Core/Demo/DemoWorld.swift CheekyPint/App/AppContainer.swift \
        CheekyPintTests/FeedRepositoryTests.swift CheekyPint.xcodeproj/project.pbxproj
git commit -m "feat: add the feed data layer with demo-mode support"
```

---

### Task 2: Authenticated post images

**Files:**
- Modify: `CheekyPint/Core/Networking/ImageLoader.swift`
- Modify: `CheekyPint/Core/Database/ProfileRepository.swift`
- Modify: `CheekyPint/Core/Networking/SupabaseData.swift` (add `objectURL(bucket:path:)`)
- Modify: `CheekyPint/App/CheekyPintApp.swift` (or wherever the container is constructed — read it first)
- Modify: `CheekyPintTests/FeedRepositoryTests.swift` (add a URL-shape test)

**Interfaces:**
- Consumes: `SupabaseAuth`'s access-token accessor — read `SupabaseAuth.swift` and use the existing one; do not add a second token path.
- Produces: `ImageLoader.setTokenProvider(_:)`; `ProfileRepository.postImageURL(for:)`.

**Why this task exists.** Post photos moved to a **private** bucket with a friend-aware `storage.objects` policy (`20260812000100_private_post_images.sql`). The public route no longer serves them. Without this task, every post photo in Task 3's feed fails to load — and it fails *silently*, because `ImageLoader` returns `nil` on a non-200 and `RemoteImage` renders its failure branch.

- [ ] **Step 1: Write the failing test**

```swift
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
```

- [ ] **Step 2: Run it to verify it fails**

Expected: FAIL to compile — no `postImageURL`.

- [ ] **Step 3: Add `postImageURL(for:)`**

Read `ProfileRepository.avatarURL(for:)` first: it delegates to `data.publicURL(bucket:path:)`,
which builds the `/storage/v1/object/public/...` route. **That route cannot serve a private bucket**,
so you need a sibling helper. Add `objectURL(bucket:path:)` to `SupabaseData` next to `publicURL`,
building the **authenticated** `/storage/v1/object/<bucket>/<path>` route, then have
`postImageURL(for:)` mirror `avatarURL`'s nil-handling and call it.

Comment both: that the authenticated route is required because `post-images` is private and its read
policy is evaluated per request, and that the asymmetry with `avatars` (still a public bucket) is
deliberate and tracked, not an oversight.

- [ ] **Step 4: Give `ImageLoader` a token**

`ImageLoader` is a singleton actor with no access to auth, and a static `httpAdditionalHeaders` cannot carry a token that refreshes. Add an injected provider:

```swift
    /// Supplies the caller's current access token. Post photos live in a private bucket whose
    /// read policy is evaluated per request, so every fetch must carry the caller's identity;
    /// a static header cannot, because tokens refresh.
    private var tokenProvider: (@Sendable () async -> String?)?

    func setTokenProvider(_ provider: @escaping @Sendable () async -> String?) {
        tokenProvider = provider
    }
```

Then build a request per fetch instead of using `session.data(from:)`:

```swift
            var request = URLRequest(url: url)
            if let token = await tokenProvider?() {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data)
            else { return nil }
```

Note the ordering trap: `tokenProvider` is actor state, so read it **before** entering the detached `Task`, or capture it explicitly — do not reach back into the actor from inside the task closure in a way that reintroduces a suspension per image.

While you are here, fix the stale rationale. The `User-Agent` comment still cites Wikimedia's robot policy, but the beer photos it referred to were removed — the loader now serves Supabase Storage. Rewrite that comment to say what is true, and keep the header itself (a descriptive UA is good manners regardless). Same for the `BeerImages` cache directory name: leave the directory alone (renaming it orphans existing caches for no user benefit) but comment why the name no longer matches its contents.

- [ ] **Step 5: Wire the provider at launch**

Read `CheekyPintApp.swift` and `AppContainer.swift` to find where the container is built, then set the provider once at startup so it is in place before any feed renders. Use the container's `auth`. Keep it to one call — do not thread the provider through views.

- [ ] **Step 6: Run the tests**

Expected: all app tests pass, 54 core, 87 SQL.

- [ ] **Step 7: Commit**

```bash
git add CheekyPint/Core/Networking/ImageLoader.swift CheekyPint/Core/Database/ProfileRepository.swift \
        CheekyPint/App/CheekyPintApp.swift CheekyPintTests/FeedRepositoryTests.swift
git commit -m "feat: authenticate post-image fetches against the private bucket"
```

---

### Task 3: The Feed tab

**Files:**
- Create: `CheekyPint/Features/Feed/FeedViewModel.swift`
- Create: `CheekyPint/Features/Feed/FeedView.swift`
- Create: `CheekyPint/Features/Feed/FeedPostCard.swift`
- Modify: `CheekyPint/Features/Home/MainTabView.swift`
- Create: `CheekyPintUITests/FeedUITests.swift`

**Interfaces:**
- Consumes: `AppContainer.feed`, `FeedPostDTO`, `FeedCursor`, `ProfileRepository.postImageURL(for:)`, `RemoteImage`, `RemoteAvatar`.
- Produces: a fourth tab, `Logger | Feed | Leaderboard | Settings`.

- [ ] **Step 1: Write the failing UI test**

Create `CheekyPintUITests/FeedUITests.swift`, following `OnboardingUITests`'s structure (it uses the `-uiTestDemo` launch argument, which needs no database):

```swift
import XCTest

final class FeedUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    @MainActor
    func testFeedTabShowsSeededDemoPosts() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestDemo"]
        app.launch()

        let feedTab = app.tabBars.buttons["Feed"]
        XCTAssertTrue(feedTab.waitForExistence(timeout: 10), "the app should have a Feed tab")
        feedTab.tap()

        // The demo world seeds three posts; at least one body must be on screen.
        XCTAssertTrue(app.staticTexts["Prague"].waitForExistence(timeout: 10),
                      "the seeded post's place label should render")
    }

    @MainActor
    func testCheersToggleUpdatesItsLabel() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestDemo"]
        app.launch()
        app.tabBars.buttons["Feed"].tap()

        let cheers = app.buttons.matching(identifier: "cheers-toggle").firstMatch
        XCTAssertTrue(cheers.waitForExistence(timeout: 10), "each post needs a Cheers control")
        let before = cheers.label
        cheers.tap()
        // The label carries the count, so it must change when toggled.
        XCTAssertTrue(cheers.waitForNonExistence(timeout: 0.1) == false)
        XCTAssertNotEqual(cheers.label, before, "toggling Cheers should change the control's label")
    }
}
```

If the seeded place label differs from `"Prague"`, use whatever Task 1 actually seeded and say so — do not change the seed to match the test.

- [ ] **Step 2: Run it to verify it fails**

```bash
xcodebuild test -project CheekyPint.xcodeproj -scheme CheekyPint \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build \
  -only-testing:CheekyPintUITests/FeedUITests 2>&1 | tail -20
```

Expected: FAIL — there is no Feed tab.

- [ ] **Step 3: Write `FeedViewModel`**

Match `HomeViewModel`'s shape: `@MainActor @Observable final class`, holding `container`, `private(set) var posts: [FeedPostDTO]`, `private(set) var isLoading`, `private(set) var loadError: SupabaseError?`, and a `hasMore` flag.

- `load()` — first page, clears existing posts, sets `loadError` on failure.
- `loadMore()` — pages using `posts.last?.cursor`; no-op while loading or when `hasMore` is false. Set `hasMore = false` when a page returns fewer rows than requested.
- `refresh()` — for pull-to-refresh; same as `load()` but without clearing until the new page arrives, so the list doesn't flash empty.
- `toggleCheers(_ post:)` — **optimistic with rollback.** Flip `viewerHasCheered` and adjust `cheersCount` locally, call the RPC, then reconcile from the returned `cheered`/`cheersCount` rather than trusting the local guess. On error, restore the previous values and surface the error. Two rapid taps by the same user converge to un-cheered server-side by design, so reconciling from the response is what keeps the UI honest.

Since `FeedPostDTO` is a `let`-only struct, either make the mutable display fields `var`, or hold a small `FeedPostState` wrapper. Pick one, and say which in your report — do not mutate a DTO by re-decoding it.

- [ ] **Step 4: Write `FeedPostCard`**

One post, styled with `coasterCard()`. Contents, top to bottom:

- header row: `RemoteAvatar(url:name:size:)` for the author (use `container.avatarURL(for:)`), `displayName` in `Theme.Typography.headline`, relative time from `createdAt` in `Theme.Typography.caption`
- the place label when present, with `Image(systemName: "mappin.and.ellipse")`, in `Theme.Palette.textSecondary`
- the photo when `imagePath` is present: `RemoteImage(url: container.postImageURL(for:))` with the same phase handling `BeerCard` used — a `ProgressView` while loading and a neutral placeholder on failure. Constrain it to a fixed aspect ratio and clip it with `RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)`.
- the body text when present, `Theme.Typography.body`
- footer row: the Cheers control and the comment count

The Cheers control needs `.accessibilityIdentifier("cheers-toggle")` for the UI test, a label that includes the count (so the test can observe a change), and the clinking-beers glyph. Use `Theme.Palette.accent` when `viewerHasCheered`, `textSecondary` otherwise, and honour Reduce Motion on any scale effect.

The comment count is display-only in this task — Part 2 makes it tappable.

- [ ] **Step 5: Write `FeedView`**

A `NavigationStack` containing a `List` (or `ScrollView` + `LazyVStack`) of `FeedPostCard`, with:

- `.refreshable { await model.refresh() }`
- `.task { await model.load() }` on first appearance
- infinite scroll: call `loadMore()` when the last card appears
- an **empty state** that is genuinely useful — a friends-only feed is empty for a new user with no friends, so say that, rather than showing a bare spinner forever. Point them at adding friends.
- an **error state** using the same `StatusView` pattern `LeaderboardView` uses, with a Retry button
- `.pubBackground()` and the `Wordmark` in the toolbar, matching how `HomeView` presents itself

- [ ] **Step 6: Add the tab**

In `MainTabView`, insert Feed as the **second** tab so the ordering is `Logger | Feed | Leaderboard | Settings`, and renumber the `.tag` values. Use `Label("Feed", systemImage: "square.stack")` — do not reuse the clinking-beers glyph, which now means Cheers.

- [ ] **Step 7: Run everything**

```bash
xcodebuild test -project CheekyPint.xcodeproj -scheme CheekyPint \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build 2>&1 | grep -E "Executed|error:"
(cd CheekyPintCore && swift test 2>&1 | tail -2)
./supabase/tests/run_local_pg.sh 2>&1 | tail -2
```

Expected: both new UI tests pass, existing app and core suites green, SQL suite 87.

- [ ] **Step 8: See it**

Build for the simulator, launch with `-uiTestDemo`, tap the Feed tab, and screenshot it:

```bash
xcodebuild -project CheekyPint.xcodeproj -scheme CheekyPint -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build build
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null; xcrun simctl bootstatus "iPhone 17 Pro" -b
xcrun simctl install "iPhone 17 Pro" build/Build/Products/Debug-iphonesimulator/CheekyPint.app
xcrun simctl launch "iPhone 17 Pro" app.cheekypint.CheekyPint.dev -uiTestDemo
xcrun simctl io "iPhone 17 Pro" screenshot /tmp/feed-tab.png
```

Report where you saved it. A screenshot showing three seeded posts is the deliverable — this is the first task in the whole effort that produces something a user can look at.

- [ ] **Step 9: Commit**

```bash
git add CheekyPint/Features/Feed CheekyPint/Features/Home/MainTabView.swift \
        CheekyPintUITests/FeedUITests.swift CheekyPint.xcodeproj/project.pbxproj
git commit -m "feat: add the Feed tab"
```

---

## Not in this plan (Part 2)

`ComposePostSheet` (text + `PhotosPicker` + `ImageResizer`, uploading to `post-images/<uid>/<uuid>.jpg`), `PlacePickerSheet` (`MKLocalSearchCompleter` over cities and venues, no location permission), `PostCommentsSheet` with `@` mention autocomplete restricted to accepted friends, report UI for posts and comments, and the Settings export screen that calls `exportMyData()` and shares the document.

Also still open, and not this plan's business: the `reports` cascade decision, scheduling the retention jobs, the public `avatars` bucket, `nudges` sent being unreadable, and the Art. 9 classification.
