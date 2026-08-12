# Feed Client Part 2 — Compose, Places, Comments, Reports, Export

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give users the write half of the feed — post a photo or status, tag a city or pub, comment with @mentions, report content — plus the DSGVO data-export screen that Art. 15/20 requires.

**Architecture:** Part 2 is **pure client UI**. Every RPC, DTO, params struct, migration, and storage policy it needs already exists and is green under 87 SQL assertions. `FeedRepository` needs no new methods. The work is five SwiftUI surfaces plus three small demo-mode gaps and two `Info.plist` purpose strings. Each surface follows the established `LogPintSheet` shape: a plain `View` with `@State`, inline error text, an `.overlay` progress view, and `@Environment(\.dismiss)` — no view model unless the surface needs paging or optimistic reconciliation (only the comments sheet does).

**Tech Stack:** SwiftUI (iOS 17), Swift 6 strict concurrency, `PhotosUI`, `MapKit` (`MKLocalSearchCompleter`), Supabase Storage + Postgres RPCs, XcodeGen.

## Global Constraints

- **iOS deployment target 17.0** (`project.yml:8`). Do not use an iOS 18+ API. `photo.badge.exclamationmark` is iOS 18 and already caused a defect in Part 1 — check every SF Symbol.
- **Swift 6.0, `SWIFT_STRICT_CONCURRENCY: complete`** (`project.yml:20-21`). View models are `@MainActor @Observable final class`. Repositories are `Sendable` structs. `DemoWorld` is an `actor`.
- **No location permission, ever.** `PlacePickerSheet` must not touch `CLLocationManager`, `LocationService`, or any coordinate-seeded search. This is an explicit product requirement from the user: typing "Prague" must be enough.
- **Mirror these server limits client-side** (from `supabase/migrations/20260811000500_rpc_feed_posts.sql` and `20260811000600_rpc_feed_social.sql`) so the user sees a local message instead of a round-trip error:
  - post body: `left(v_body, 500)` → **500 characters**
  - place label: `left(v_label, 80)` → **80 characters**
  - a post requires a photo **or** words: `'A post needs a photo or some words'`
  - `pub_id is not null` requires a non-null place label
  - image path must be exactly `<uid>/<uuid>.jpg`; `..` anywhere is rejected; the first folder segment must equal `auth.uid()::text`
  - rate limits: `post_create` 20/hour, `post_delete` 60/hour, `data_export` 5/24h
- **Mentions are friends-only.** `add_comment` raises `'Can only mention friends'` (errcode `P0002`) if any mentioned id is not an accepted friend. The autocomplete's only data source is `FriendsRepository.fetchFriends()`; never offer a non-friend.
- **The server never parses `@name` from text** (`20260811000100_feed_tables.sql:81-90`: "Mentions recorded at write time rather than parsed on read"). The client sends an explicit `[UUID]`.
- Use `Theme.*` tokens for every colour, radius, and font. No hardcoded `Color(...)` or point sizes.
- Every interactive control gets an `accessibilityIdentifier` and an accessibility label. Part 1's UI tests locate controls this way.
- **Never run `xcrun simctl shutdown` or `shutdown all`.** Never boot, install, or launch a simulator manually. `xcodebuild test` manages its own. The user was disrupted by simulator contention earlier in this project.
- `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` in every shell invocation, or `xcodebuild` will fail.
- Run `xcodegen generate` after adding any file, and commit the regenerated `project.pbxproj`.
- Sanitise all user text through the existing `ProfileTextSanitizer` (CheekyPintCore) before sending. It handles Trojan Source characters (U+2066–2069, U+2060) that a naive trim misses.

## Reference Inventory

`/Users/nedimvejo/Projects/cheekypint/.superpowers/sdd/2026-08-12-feed-client-part2/interface-inventory.md` holds verbatim signatures for every existing method these tasks call. Read it once before Task 1; it will save you from re-deriving types.

## File Structure

| File | Responsibility |
|---|---|
| `CheekyPint/Resources/Info.plist` (modify) | Photo-library purpose string covering feed photos; location purpose string for the pre-existing `LocationService` call |
| `CheekyPint/Core/Demo/DemoWorld.swift` (modify) | Accept `pubID` in `createPost`; keep newly composed demo photos |
| `CheekyPint/Core/Database/ProfileRepository.swift` (modify) | `writeLocalPostImage` + resolve written demo post photos |
| `CheekyPint/Features/Feed/ComposePostSheet.swift` (create) | Photo + text + place → `createPost` |
| `CheekyPint/Features/Feed/PlacePickerSheet.swift` (create) | Permission-free city/pub search returning `SelectedPlace` |
| `CheekyPint/Core/Location/PlaceCompleter.swift` (create) | `MKLocalSearchCompleter` wrapper, `@MainActor @Observable` |
| `CheekyPint/Features/Feed/PostCommentsSheet.swift` (create) | Comment list + composer + @mention autocomplete |
| `CheekyPint/Features/Feed/PostCommentsViewModel.swift` (create) | Comment paging, optimistic append, mention bookkeeping |
| `CheekyPintCore/Sources/CheekyPintCore/Text/MentionScanner.swift` (create) | Pure mention-token logic, unit tested in Core |
| `CheekyPint/Features/Moderation/ReportContentView.swift` (create) | Report a post or a comment |
| `CheekyPint/Features/Settings/DataExportView.swift` (create) | Art. 15/20 export + share sheet |
| `CheekyPint/Features/Settings/SettingsView.swift` (modify) | Row linking to `DataExportView` |
| `CheekyPint/Features/Feed/FeedView.swift` (modify) | Compose button, comments navigation, report menu |

---

### Task 1: Purpose strings and demo-mode foundations

Everything later in the plan depends on this: the composer cannot pick a photo without an accurate purpose string, and demo mode cannot show a just-composed photo without somewhere to keep it.

**Files:**
- Modify: `CheekyPint/Resources/Info.plist`
- Modify: `CheekyPint/Core/Demo/DemoWorld.swift` (`createPost`, line ~402; `DemoPost`, line ~51)
- Modify: `CheekyPint/Core/Database/ProfileRepository.swift` (near `writeLocalAvatar`, line ~154; `postImageURL`, line ~141)
- Test: `CheekyPintTests/DemoComposeTests.swift` (create)

**Interfaces:**
- Consumes: `ProfileRepository.localPostImagePrefix` (existing, `"local-post-image/"`), `ProfileRepository.writeLocalAvatar` (the pattern to mirror)
- Produces:
  - `ProfileRepository.writeLocalPostImage(_ jpeg: Data) throws -> String` returning a `"local-post-image/<uuid>.jpg"` path
  - `DemoWorld.createPost(body: String?, imagePath: String?, placeLabel: String?, pubID: UUID?) -> UUID`

**Context you need.** `postImageURL(for:)` currently resolves a `local-post-image/` path with `Bundle.main.url(forResource:withExtension:)` — it only works for the **seeded** bundle asset `demo-pint.png`. A photo the user picks in demo mode is not in the bundle, so it can never resolve. `writeLocalAvatar` already solves the identical problem for avatars by writing to Application Support; mirror it, and make `postImageURL` try the written file first and fall back to the bundle lookup so the seeded post keeps working.

`FeedRepository.createPost` already accepts and forwards `pubID`, but `DemoWorld.createPost` has no such parameter, so the value is silently dropped. Add it and store it.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import CheekyPint

final class DemoComposeTests: XCTestCase {
    func testWrittenDemoPostImageResolvesToAnExistingFile() throws {
        let repo = ProfileRepository(data: .preview)
        let jpeg = try XCTUnwrap(UIImage(systemName: "photo")?.jpegData(compressionQuality: 0.8))
        let path = try repo.writeLocalPostImage(jpeg)
        XCTAssertTrue(path.hasPrefix("local-post-image/"), "got \(path)")
        let url = try XCTUnwrap(repo.postImageURL(for: path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "a composed demo photo must resolve to a real file, not a bundle miss")
    }

    func testSeededBundleDemoPostImageStillResolves() throws {
        let repo = ProfileRepository(data: .preview)
        let url = try XCTUnwrap(repo.postImageURL(for: "local-post-image/demo-pint.png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "the seeded bundle asset must keep resolving after the fallback change")
    }

    func testDemoCreatePostKeepsThePubID() async throws {
        let world = DemoWorld.shared
        await world.activateForTesting()
        let pubID = UUID()
        let postID = await world.createPost(body: "Pub post", imagePath: nil,
                                            placeLabel: "The Kings Arms", pubID: pubID)
        let page = await world.feedPage(before: nil, limit: 50)
        let post = try XCTUnwrap(page.first { $0.postId == postID })
        XCTAssertEqual(post.pubId, pubID, "pubID must survive the demo write path")
        XCTAssertEqual(post.placeLabel, "The Kings Arms")
    }
}
```

If `ProfileRepository(data: .preview)` or `activateForTesting()` do not exist under those names, find the equivalents the existing `CheekyPintTests/FeedRepositoryTests.swift` uses and match them exactly — do not invent a test seam.

- [ ] **Step 2: Run and watch it fail**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild test -project CheekyPint.xcodeproj -scheme CheekyPint \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:CheekyPintTests/DemoComposeTests 2>&1 | tail -20
```
Expected: compile failure — `writeLocalPostImage` and the 4-argument `createPost` do not exist.

- [ ] **Step 3: Add `writeLocalPostImage` and the resolution fallback**

Mirror `writeLocalAvatar` exactly, including its directory-creation and error handling, but into a `CheekyPintPostImages` directory. Then make `postImageURL(for:)` check the written-file location before the bundle:

```swift
// inside postImageURL(for:), replacing the current bundle-only branch
if path.hasPrefix(Self.localPostImagePrefix) {
    let filename = String(path.dropFirst(Self.localPostImagePrefix.count))
    // A photo composed in demo mode was written to Application Support; the seeded post's
    // photo ships in the bundle. Try the written file first, because a bundle lookup for a
    // just-picked photo can never succeed.
    let written = Self.localPostImageDirectory().appending(path: filename)
    if FileManager.default.fileExists(atPath: written.path) { return written }
    let name = (filename as NSString).deletingPathExtension
    let ext = (filename as NSString).pathExtension
    return Bundle.main.url(forResource: name, withExtension: ext)
}
```

- [ ] **Step 4: Thread `pubID` through `DemoWorld.createPost`**

Add `pubID: UUID?` as the fourth parameter, store it in the `DemoPost` (the field already exists as `let pubID: UUID?`), and update `FeedRepository`'s demo branch to pass it.

- [ ] **Step 5: Add both `Info.plist` purpose strings**

Replace the photo-library string — its current text says only "profile picture", which will not match the app's actual use once the composer ships, and an inaccurate purpose string is an App Review rejection point:

```xml
<key>NSPhotoLibraryUsageDescription</key>
<string>CheekyPint lets you choose a profile picture and add photos to your posts.</string>
<key>NSLocationWhenInUseUsageDescription</key>
<string>CheekyPint can find pubs near you when you tap “Search near me”. You can always search by name instead.</string>
```

The location key fixes a **pre-existing bug unrelated to Part 2**: `LocationService.requestWhenInUseAuthorization()` (`CheekyPint/Core/Location/LocationService.swift:30`) is reachable from `PubPickerView` and `PubsView`, but with no usage-description key iOS ignores the request, so "Search near me" can never work. Add the key; do not otherwise touch the location code, and do **not** use it from `PlacePickerSheet`.

- [ ] **Step 6: Run the tests to green, then the full suites**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild test -project CheekyPint.xcodeproj -scheme CheekyPint \
  -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -30
swift test --package-path CheekyPintCore 2>&1 | tail -10
```
`OnboardingUITests.testWelcomeShowsResponsibleUseAndAgeGate` fails on the clean base — ignore that one, but nothing else may regress.

- [ ] **Step 7: Prove the gate**

Revert only the `postImageURL` fallback (leave `writeLocalPostImage`) and confirm `testWrittenDemoPostImageResolvesToAnExistingFile` **fails**. Restore. Report the exact failure message. A test that passes with the fix removed is not a test.

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "feat: demo-mode post photos and accurate purpose strings"
```

---

### Task 2: ComposePostSheet

**Files:**
- Create: `CheekyPint/Features/Feed/ComposePostSheet.swift`
- Modify: `CheekyPint/Features/Feed/FeedView.swift`
- Modify: `CheekyPint/Features/Feed/FeedViewModel.swift` (insert a new post at the head)
- Test: `CheekyPintTests/ComposePostTests.swift` (create)

**Interfaces:**
- Consumes: `FeedRepository.createPost(body:imagePath:placeLabel:pubID:) -> UUID`, `SupabaseData.uploadObject(bucket:path:data:contentType:) -> String`, `ImageResizer.jpeg(from:maxDimension:quality:) -> Data?`, `ProfileRepository.writeLocalPostImage(_:) -> String` (Task 1)
- Produces: `ComposePostSheet(onPosted: @escaping () async -> Void)`; `FeedViewModel.reload()` (use the existing method if present, else add)

**Design decisions already made for you.**

`ImageResizer`'s default `maxDimension: 512` is avatar-sized and would make feed photos look terrible. Use **1600** with the default `quality: 0.8`: large enough for a full-width card on a 3x display, small enough that a pub photo lands around 300–500 KB. Pass it explicitly so the choice is visible at the call site.

The storage path must be `"\(uid)/\(UUID().uuidString).jpg"` — the server checks the first folder segment against `auth.uid()::text` and rejects anything containing `..`. Mirror `ProfileRepository.uploadAvatar` (`ProfileRepository.swift:104-116`), which builds exactly this shape.

Order of operations matters: **upload the photo first, then call `createPost`.** If `createPost` fails you have an orphaned object (the retention GC sweeps those); if you created the row first and the upload failed you would have a post pointing at nothing, which renders as the "Photo unavailable" state forever.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import CheekyPint

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
```

- [ ] **Step 2: Run and watch it fail.** Expected: `ComposePostSheet` does not exist.

- [ ] **Step 3: Build the sheet**

Make `canPost`, `storagePath`, and the two limits `static` so they are testable without a view. Follow `LogPintSheet`'s shape: `Form`, inline `Text(errorMessage).foregroundStyle(Theme.Palette.warning)`, `@State private var isPosting`, guarded re-entrancy, `.overlay { if isPosting { ProgressView() … } }`, `.presentationDetents([.large])`, dismiss then callback.

```swift
struct ComposePostSheet: View {
    static let bodyLimit = 500
    static let placeLabelLimit = 80

    static func canPost(body: String, hasPhoto: Bool) -> Bool {
        hasPhoto || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func storagePath(uid: UUID) -> String {
        "\(uid.uuidString)/\(UUID().uuidString).jpg"
    }
    …
}
```

Requirements:
- `PhotosPicker(selection: $pickedItem, matching: .images)`, loaded via `item.loadTransferable(type: Data.self)` exactly as `EditProfileView.loadAvatar` does. Show a thumbnail with a "Remove photo" button once picked.
- A `TextField("What's in the glass?", text: $body, axis: .vertical).lineLimit(3...8)` with a live `\(body.count)/500` counter that turns `Theme.Palette.warning` past the limit. Disable Post past the limit rather than silently truncating — the server truncates, and a user who wrote 600 characters should not discover 100 vanished after posting.
- A place row showing the selected label or "Add a location", opening Task 3's `PlacePickerSheet`. **For this task, stub the row as a disabled placeholder** and wire it in Task 3; note that clearly in a comment so the reviewer does not read it as an omission.
- Sanitise `body` and the place label through `ProfileTextSanitizer` before sending.
- Demo mode: when `DemoWorld.shared.isActive`, write the JPEG with `writeLocalPostImage` and pass that path instead of uploading.
- `accessibilityIdentifier`: `"compose-post-body"`, `"compose-post-photo"`, `"compose-post-submit"`.

- [ ] **Step 4: Wire it into `FeedView`**

Add a toolbar button (`square.and.pencil`, identifier `"feed-compose"`) presenting the sheet, and on success reload the feed so the new post appears at the head.

- [ ] **Step 5: Run tests to green, then all suites** (commands as Task 1 Step 6).

- [ ] **Step 6: Verify visually.** Write a throwaway UI test launching with `-uiTestDemo`, tapping the Feed tab then `"feed-compose"`, and screenshotting to `/tmp/compose-check.png` via `XCUIScreen.main.screenshot().pngRepresentation`. **Read the PNG back** and confirm the sheet renders with no clipped or overflowing content — Part 1 shipped a card-overflow bug that every test passed. Then delete the throwaway test and re-run `xcodegen generate`.

- [ ] **Step 7: Prove the gate.** Change `canPost` to `true` unconditionally and confirm `testPostIsRejectedLocallyWhenEmpty` fails. Restore. Report the message.

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "feat: compose a feed post with a photo or words"
```

---

### Task 3: PlacePickerSheet — cities and pubs, no permission

**Files:**
- Create: `CheekyPint/Core/Location/PlaceCompleter.swift`
- Create: `CheekyPint/Features/Feed/PlacePickerSheet.swift`
- Modify: `CheekyPint/Features/Feed/ComposePostSheet.swift` (activate the place row)
- Test: `CheekyPintTests/PlacePickerTests.swift` (create)

**Interfaces:**
- Consumes: `PubsRepository.persist(_ result: PubSearchResult) async throws -> Pub` (`PubsRepository.swift:107`) — reuses an existing pub by name+city or inserts one, returning a row with a stable `id`
- Produces: `struct SelectedPlace: Equatable, Sendable { let label: String; let pubID: UUID? }`

**The product requirement, verbatim from the user:** "you can just add prague, and thats it so the locations can be cities too but also pubs". So **typed free text alone must be sufficient** — the picker must never force the user to choose a suggestion, and must never ask for location permission.

**Why not reuse `PubsRepository.search`:** it drives `MKLocalSearch` with `MKPointOfInterestFilter(including: [.brewery, .restaurant, .nightlife])`, which is wrong for a bare city lookup — "Prague" would come back as restaurants in Prague, not the city. Use `MKLocalSearchCompleter` with `resultTypes = [.address, .pointOfInterest]` and **no region**, which returns both cities and venues without any authorisation. Nothing in the repo uses the completer yet, so there is no prior art to copy.

**How a pub gets a real `pub_id`:** completions do not carry coordinates or a POI category. On selection, resolve the completion with `MKLocalSearch(request: MKLocalSearch.Request(completion:))` to get an `MKMapItem`. If its `pointOfInterestCategory` is one of `.brewery`, `.restaurant`, `.nightlife`, `.cafe`, or `.bakery`, build a `PubSearchResult` from the map item and call `pubs.persist(_:)` to obtain a `pubID`. Otherwise treat it as a place and return a label with `pubID: nil`. If resolution or `persist` fails, **fall back to label-only** — a failed lookup must never block posting.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import MapKit
@testable import CheekyPint

final class PlacePickerTests: XCTestCase {
    func testTypedTextAloneIsAValidPlace() {
        let place = PlacePickerSheet.freeTextPlace(from: "  Prague  ")
        XCTAssertEqual(place?.label, "Prague", "typed text is trimmed and used verbatim")
        XCTAssertNil(place?.pubID, "a typed city has no pub row")
        XCTAssertNil(PlacePickerSheet.freeTextPlace(from: "   "), "whitespace is not a place")
    }

    func testLabelIsClampedToTheServerLimit() {
        let long = String(repeating: "a", count: 200)
        let place = PlacePickerSheet.freeTextPlace(from: long)
        XCTAssertEqual(place?.label.count, 80,
                       "server truncates place_label at 80; clamp before sending")
    }

    func testPubCategoriesAreTreatedAsPubsAndOthersAsPlaces() {
        XCTAssertTrue(PlacePickerSheet.isPubCategory(.brewery))
        XCTAssertTrue(PlacePickerSheet.isPubCategory(.nightlife))
        XCTAssertFalse(PlacePickerSheet.isPubCategory(.airport))
        XCTAssertFalse(PlacePickerSheet.isPubCategory(nil))
    }

    func testCompleterNeverRequestsAuthorization() {
        // The whole point of this picker: it must not depend on CLLocationManager at all.
        let source = try! String(contentsOfFile: #filePath.replacingOccurrences(
            of: "CheekyPintTests/PlacePickerTests.swift",
            with: "CheekyPint/Features/Feed/PlacePickerSheet.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("CLLocationManager"))
        XCTAssertFalse(source.contains("LocationService"))
        XCTAssertFalse(source.contains("requestWhenInUseAuthorization"))
    }
}
```

The last test is deliberately a source-text assertion: the requirement is the *absence* of a dependency, which no behavioural test can observe. If you find a cleaner way to enforce it, use that instead and say so.

- [ ] **Step 2: Run and watch it fail.**

- [ ] **Step 3: Write `PlaceCompleter`**

An `@MainActor @Observable final class` wrapping `MKLocalSearchCompleter` behind an `MKLocalSearchCompleterDelegate`. Expose `var query: String` (fed to `completer.queryFragment`) and `private(set) var results: [MKLocalSearchCompletion]`. Set `resultTypes = [.address, .pointOfInterest]`. Do **not** set `region`. Handle `completer(_:didFailWithError:)` by clearing results — a failed completion is not an error worth showing, since typed text always works.

`MKLocalSearchCompleter` is not `Sendable`; keep the whole class `@MainActor` and do not hop off it.

- [ ] **Step 4: Write `PlacePickerSheet`**

- A searchable list. The **first row is always** `Use "<typed text>"` when the field is non-empty, so free text is reachable in one tap.
- Below it, completion rows showing `title` and `subtitle`.
- Selecting a completion resolves it as described above; show a small inline progress indicator during resolution and fall back to label-only on failure.
- `accessibilityIdentifier`: `"place-search-field"`, `"place-use-typed"`, `"place-result-\(index)"`.
- Clamp every label to 80 characters via one shared helper so free text and resolved venues cannot diverge.

- [ ] **Step 5: Activate the composer's place row**, replacing Task 2's disabled placeholder. Show the label with a clear "Remove" affordance, and pass `placeLabel` + `pubID` into `createPost`.

- [ ] **Step 6: Run tests to green, then all suites.**

- [ ] **Step 7: Verify visually.** Throwaway UI test: compose sheet → tap the place row → type "Prague" → screenshot to `/tmp/place-check.png`. Read it back; confirm the "Use "Prague"" row is present and nothing is clipped. Delete the test, `xcodegen generate`.

- [ ] **Step 8: Prove the gate.** Remove the 80-character clamp and confirm `testLabelIsClampedToTheServerLimit` fails. Restore.

- [ ] **Step 9: Commit**

```bash
git add -A && git commit -m "feat: tag a city or pub on a post without location permission"
```

---

### Task 4: PostCommentsSheet with @mention autocomplete

**Files:**
- Create: `CheekyPintCore/Sources/CheekyPintCore/Text/MentionScanner.swift`
- Create: `CheekyPint/Features/Feed/PostCommentsViewModel.swift`
- Create: `CheekyPint/Features/Feed/PostCommentsSheet.swift`
- Modify: `CheekyPint/Features/Feed/FeedPostCard.swift` (comment button opens the sheet)
- Test: `CheekyPintCore/Tests/CheekyPintCoreTests/MentionScannerTests.swift` (create)
- Test: `CheekyPintTests/PostCommentsViewModelTests.swift` (create)

**Interfaces:**
- Consumes: `FeedRepository.comments(postID:before:limit:) -> [PostCommentDTO]`, `FeedRepository.addComment(postID:body:mentions:) -> UUID`, `FeedRepository.deleteComment(_:)`, `FriendsRepository.fetchFriends() -> [FriendDTO]`
- Produces: `MentionScanner.activeToken(in:upTo:) -> String?`, `MentionScanner.stillPresent(mentions:in:) -> [UUID]`, `PostCommentsSheet(postID: UUID, onCommentCountChanged: @escaping (Int) -> Void)`

**Mention design — read this before writing code.** Re-parsing `@names` out of free text on send is fragile: display names contain spaces, so `@Barnaby Pemberton-Smythe` has no unambiguous end. Instead:

1. As the user types, `MentionScanner.activeToken(in:upTo:)` finds the `@token` under the cursor.
2. Filter `fetchFriends()` by that token and show an autocomplete row per match. **Friends are the only source** — the server rejects a non-friend mention with `'Can only mention friends'`.
3. On selection, replace the active token with `@<displayName> ` and record `[UUID: displayName]` in a dictionary.
4. On send, `MentionScanner.stillPresent(mentions:in:)` keeps only the ids whose `@displayName` still literally appears in the final text — so deleting a mention drops it, and no re-parse is needed.

`MentionScanner` is pure text logic with no SwiftUI or Supabase dependency, so it belongs in `CheekyPintCore` alongside `ProfileTextSanitizer`, and is tested with `swift test`.

- [ ] **Step 1: Write the failing Core tests**

```swift
import XCTest
@testable import CheekyPintCore

final class MentionScannerTests: XCTestCase {
    func testFindsTheTokenUnderTheCursor() {
        XCTAssertEqual(MentionScanner.activeToken(in: "cheers @bar", upTo: 11), "bar")
        XCTAssertEqual(MentionScanner.activeToken(in: "@ce", upTo: 3), "ce")
        XCTAssertNil(MentionScanner.activeToken(in: "no mention here", upTo: 15))
        XCTAssertNil(MentionScanner.activeToken(in: "email a@b.com", upTo: 13),
                     "an @ with no preceding boundary is not a mention")
    }

    func testTokenEndsAtTheCursorNotTheEndOfText() {
        XCTAssertEqual(MentionScanner.activeToken(in: "@bar and @ceri", upTo: 4), "bar")
    }

    func testKeepsOnlyMentionsStillPresentInTheText() {
        let a = UUID(), b = UUID()
        let mentions = [a: "Barnaby", b: "Ceri"]
        let kept = MentionScanner.stillPresent(mentions: mentions, in: "cheers @Barnaby")
        XCTAssertEqual(kept, [a], "a deleted mention must not be sent to the server")
    }

    func testEmptyWhenNoMentionSurvives() {
        XCTAssertTrue(MentionScanner.stillPresent(mentions: [UUID(): "Barnaby"],
                                                  in: "plain text").isEmpty)
    }
}
```

- [ ] **Step 2: Run and watch it fail.**

```bash
swift test --package-path CheekyPintCore --filter MentionScannerTests 2>&1 | tail -15
```

- [ ] **Step 3: Implement `MentionScanner`.** Keep it a plain `public enum` with static methods. Treat a mention as starting at an `@` that is at index 0 or preceded by whitespace, and running to the cursor. Return `nil` if the token contains a newline.

- [ ] **Step 4: Write the failing view-model tests**

Follow `FeedViewModelTests`' existing seam style — `PostCommentsViewModel` takes injectable closures (`commentsRequest`, `addCommentRequest`) defaulting to the real repository calls **inside the init body**, not as default parameter expressions (Swift cannot reference sibling parameters there; this exact mistake cost a fix round in Part 1). Cover at minimum:
- a successful send appends the comment and reports the new count via `onCommentCountChanged`
- a failed send leaves the list unchanged and surfaces an error, and does **not** report a count change
- paging with a `FeedCursor` does not duplicate or drop the boundary comment

- [ ] **Step 5: Implement the view model, then the sheet.** Comment rows show avatar, display name, relative time (reuse Part 1's `RelativeDateTimeFormatter` approach — "30 min ago", not "30 min, 7 secs"), and body with mentions rendered in `Theme.Palette.forest`. Own comments get a swipe-to-delete. Composer pinned at the bottom with the autocomplete list above it when a token is active. Identifiers: `"comment-body-field"`, `"comment-send"`, `"mention-suggestion-\(index)"`.

- [ ] **Step 6: Wire the comment button** in `FeedPostCard` to present the sheet, and update the card's comment count from `onCommentCountChanged`.

- [ ] **Step 7: Run all suites.**

- [ ] **Step 8: Verify visually.** Throwaway UI test: Feed → tap a post's comment button → type `@` → screenshot to `/tmp/comments-check.png`. Read it back; confirm the sheet and the suggestion list render and the composer is not hidden behind the keyboard. Delete the test, `xcodegen generate`.

- [ ] **Step 9: Prove the gate.** Make `stillPresent` return all mention ids regardless of the text and confirm `testKeepsOnlyMentionsStillPresentInTheText` fails. Restore. Report the message.

- [ ] **Step 10: Commit**

```bash
git add -A && git commit -m "feat: comment on posts and mention friends"
```

---

### Task 5: Report a post or a comment

**Files:**
- Create: `CheekyPint/Features/Moderation/ReportContentView.swift`
- Modify: `CheekyPint/Features/Feed/FeedPostCard.swift` (overflow menu)
- Modify: `CheekyPint/Features/Feed/PostCommentsSheet.swift` (per-comment menu)
- Test: `CheekyPintTests/ReportContentTests.swift` (create)

**Interfaces:**
- Consumes: `FeedRepository.reportPost(_:category:details:)`, `FeedRepository.reportComment(_:category:details:)`, `ReportCategory` (CheekyPintCore, 7 cases, already includes `inappropriatePostImage`)
- Produces: `ReportContentView(target: ReportTarget)` where `enum ReportTarget { case post(UUID), comment(UUID) }`

`CheekyPint/Features/Moderation/ReportUserView.swift` is the template — copy its structure (Form, `Picker` over `ReportCategory.allCases`, optional details `TextField`, `sent` confirmation label, inline error, Cancel/Send toolbar, 1-second delay then dismiss). One view handles both targets via the enum; do not write two near-identical views.

Default the category sensibly per target: `.inappropriatePostImage` when the reported post has a photo, otherwise `.inappropriateText`.

- [ ] **Step 1: Write the failing test** — assert the default category per target and that `ReportTarget` routes to the correct repository call (inject the two calls as closures so the test can observe which fired, matching the `FeedViewModel` seam style).
- [ ] **Step 2: Run and watch it fail.**
- [ ] **Step 3: Implement `ReportContentView`.**
- [ ] **Step 4: Add the menus.** A `Menu` on the post card (`ellipsis`, identifier `"post-menu-\(postID)"`) offering Report and, for the viewer's own posts, Delete with a confirmation dialog. Same for comments.
- [ ] **Step 5: Run all suites.**
- [ ] **Step 6: Prove the gate.** Make both targets call `reportPost` and confirm the routing test fails. Restore.
- [ ] **Step 7: Commit** — `git commit -m "feat: report or delete a post or comment"`

**Context:** demo mode's report calls are no-ops today — `FeedRepository.reportPost` early-returns when `DemoWorld.shared.isActive` and keeps no local record. `ReportUserView` already behaves this way, treating "the call did not throw" as the entire success signal. Implement to match that existing behaviour, and make sure the confirmation copy does not claim more than "we received this".

---

### Task 6: DSGVO data export screen

**Files:**
- Create: `CheekyPint/Features/Settings/DataExportView.swift`
- Modify: `CheekyPint/Features/Settings/SettingsView.swift`
- Test: `CheekyPintTests/DataExportTests.swift` (create)

**Interfaces:**
- Consumes: `FeedRepository.exportMyData() async throws -> Data` (returns the server's raw JSON bytes, deliberately undecoded so the user receives exactly the document the server produced)

**Legal context.** This satisfies DSGVO Art. 15 (access) and Art. 20 (portability), which the project must meet under Austrian DSG. `export_my_data()` returns 14 collections plus `exported_at` and a `truncated` flag; each collection caps at 10,000 rows. **If `truncated` is true you must tell the user**, because a silently partial export does not satisfy Art. 15 — the person cannot know what is missing. The RPC is rate-limited to 5 per 24 hours, so surface that error clearly rather than as a generic failure.

- [ ] **Step 1: Write the failing tests** — assert the view writes the bytes **verbatim** (byte-for-byte equal to what the repository returned, no re-encode), that a `truncated: true` document produces a user-visible warning, and that the filename is stable and dated (e.g. `cheekypint-export-2026-08-12.json`).
- [ ] **Step 2: Run and watch it fail.**
- [ ] **Step 3: Implement `DataExportView`.** Structure it like `DeleteAccountView`: explain plainly what the file contains, one primary action, `isExporting` state, inline error, `.overlay` progress. Write the bytes to a temporary file and hand it to `ShareLink` — do not decode and re-encode the JSON, and do not render it on screen. Show the `truncated` warning when present.
- [ ] **Step 4: Add the Settings row** in the existing "Privacy" section: `NavigationLink { DataExportView() } label: { Label("Download my data", systemImage: "square.and.arrow.down") }`, matching the section's existing idiom.
- [ ] **Step 5: Run all suites.**
- [ ] **Step 6: Verify visually.** Throwaway UI test: Settings → Privacy → Download my data → screenshot. Read it back. Delete, `xcodegen generate`.
- [ ] **Step 7: Prove the gate.** Hide the truncated warning unconditionally and confirm that test fails. Restore. Report the message.
- [ ] **Step 8: Commit** — `git commit -m "feat: download my data (DSGVO Art. 15/20)"`

---

## Out of scope

- Editing a posted post (the backend has no update RPC; adding one is separate work).
- Push notifications for mentions (`nudges` exists but "sent readable by no path" is an open backend question).
- Making the `avatars` bucket private (open decision, tracked separately).
- The `reports` FK cascade issue — a reported user can currently erase reports about them. **Open backend decision for the user, not this plan.**
