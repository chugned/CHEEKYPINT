# Instant Beer Logging + Nudge Rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Tasks:** 4 (Task 1 merges the original Tasks 1-2 so it ends on a green build).

**Goal:** Remove the licence-violating Wikimedia beer photos, make logging a single tap, and rename the friend "Cheers" nudge to "Nudge" so the Cheers name is free for the upcoming feed reaction.

**Architecture:** Parts A and C of `docs/superpowers/specs/2026-08-11-social-feed-design.md`. Part A strips the remote-image layer from `BeerCatalog` and replaces the photo card grid with a compact tap-to-log list, moving serving/time/note/alcohol-free into a collapsed `Details` disclosure. Part C is a mechanical rename across SQL, the data layer, and the leaderboard UI. Part B (the feed) is a separate plan and is **not** in scope here.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, XcodeGen, Supabase (Postgres + RPCs), XCTest.

## Global Constraints

- Swift language mode 6, `SWIFT_STRICT_CONCURRENCY = complete`. New code must be `Sendable`-clean.
- Build with Xcode's toolchain: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. `xcode-select` points at the CLT, so a bare `swift`/`xcodebuild` will fail or lack XCTest.
- Device signing: `DEVELOPMENT_TEAM=C5342YYG52`, `-allowProvisioningUpdates`. Free personal team — profiles expire every 7 days.
- Regenerate the project with `xcodegen generate` after adding or deleting any file.
- **`WelfareMonitor.PintFeedbackTone.cheers` and `WelfareMonitor.cheersMessage` must NOT be renamed.** They are the post-log confirmation copy ("Pint logged. Cheers."), unrelated to the nudge. This also means `HomeViewModel.swift`, `corecheck/main.swift`, `WelfareMonitor.swift` and `SafetyAndTotalsTests.swift` match a grep for "cheers" but are out of scope.
- The alcohol-free toggle must survive. `WelfareMonitor` counts *alcoholic* entries to decide when to show the welfare notice; `docs/RESPONSIBLE_DRINKING.md` treats this as a hard product requirement.
- No new third-party dependencies. The app ships with zero.
- Existing suites must stay green after every task: **54 `CheekyPintCore` tests** and **8 app tests**.
- Work happens on branch `feat/instant-log-nudge`, cut from a clean tree (baseline commit `3a7c82b`). Commit at the end of each task as the steps instruct. Never commit on `master`, and never amend or rebase existing commits.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `CheekyPint/Features/PintLogging/LogPintSheet.swift` | Beer catalog + logging sheet | Strip image layer; card grid → tap-to-log list; `Details` disclosure; per-tap idempotency |
| `CheekyPintTests/BeerImageURLTests.swift` | Pinned the Commons URL format | Delete — the URLs cease to exist |
| `FRIEND_CIRCLE_NOTES.md` | Catalog notes | Lines 42-46 describe Wikimedia loading; rewrite |
| `supabase/migrations/20260803000000_cheers.sql` | Nudge table + RPC | Rename file and contents to `nudges` / `send_nudge` |
| `supabase/tests/rls_rpc_suite.sql` | RLS coverage | Rename the covered RPC |
| `CheekyPint/Core/Database/RPCContracts.swift` | RPC DTOs | `CheersParams`/`CheersDTO` → `NudgeParams`/`NudgeDTO` |
| `CheekyPint/Core/Database/FriendsRepository.swift` | Friend RPCs | `sendCheers`/`fetchReceivedCheers` → `sendNudge`/`fetchReceivedNudges` |
| `CheekyPint/Core/Demo/DemoWorld.swift` | Offline demo backend | `DemoCheers` → `DemoNudge`, seeded state, copy |
| `CheekyPint/Features/Leaderboard/LeaderboardRowView.swift` | Row + nudge button | `CheersButtonState` → `NudgeButtonState`, labels |
| `CheekyPint/Features/Leaderboard/LeaderboardView.swift` | Leaderboard screen | State, alerts, confirmation copy |
| `CheekyPintUITests/OnboardingUITests.swift` | UI test | Rename test + button labels |

`ImageLoader.swift` and `RemoteImage.swift` are **kept untouched** — Part B uses them for feed photos.

---

### Task 1: Instant tap-to-log (strip images, add Details disclosure)

**Files:**
- Modify: `CheekyPint/Features/PintLogging/LogPintSheet.swift`
- Delete: `CheekyPintTests/BeerImageURLTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `BeerChoice(id:name:country:style:nickname:glassNote:roast:)` — no `imageURL`, no `sourceURL`. `BeerCatalog.beers: [BeerChoice]` still has 98 entries. `BeerCatalog.diaryNote(for:userNote:)` unchanged.

- [ ] **Step 1: Write the failing test**

Replace the whole of `CheekyPintTests/BeerImageURLTests.swift` with a catalog-shape test at `CheekyPintTests/BeerCatalogTests.swift`:

```swift
import XCTest
@testable import CheekyPint

/// The catalog no longer carries imagery. These pin the shape that survived so the 98 entries
/// and the diary-note behaviour cannot regress while the image layer is removed.
final class BeerCatalogTests: XCTestCase {

    func testCatalogStillHasEveryBeer() {
        XCTAssertEqual(BeerCatalog.beers.count, 98)
    }

    func testEveryBeerHasDisplayableText() {
        for beer in BeerCatalog.beers {
            XCTAssertFalse(beer.name.isEmpty, "\(beer.id) has no name")
            XCTAssertFalse(beer.country.isEmpty, "\(beer.id) has no country")
            XCTAssertFalse(beer.style.isEmpty, "\(beer.id) has no style")
        }
    }

    func testBeerIDsAreUnique() {
        XCTAssertEqual(Set(BeerCatalog.beers.map(\.id)).count, BeerCatalog.beers.count)
    }

    func testDiaryNoteIncludesTheBeerName() {
        let beer = BeerCatalog.beers[0]
        let note = BeerCatalog.diaryNote(for: beer, userNote: "")
        XCTAssertTrue(note.contains(beer.name), "expected \(beer.name) in \(note)")
    }
}
```

Then delete the old file:

```bash
rm CheekyPintTests/BeerImageURLTests.swift
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd ~/Projects/cheekypint && xcodegen generate
xcodebuild test -project CheekyPint.xcodeproj -scheme CheekyPint \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build \
  -only-testing:CheekyPintTests/BeerCatalogTests 2>&1 | tail -20
```

Expected: **FAIL to compile** — `BeerImageURLTests.swift` referenced `imageURL`, and after Step 3 the property is gone. (If it passes at this point, the deletion in Step 1 did not happen.)

- [ ] **Step 3: Remove the image layer**

In `LogPintSheet.swift`, delete the `CryptoKit` import:

```swift
import SwiftUI
import CheekyPintCore
```

Remove `imageURL` and `sourceURL` from the model:

```swift
struct BeerChoice: Identifiable, Hashable {
    let id: String
    let name: String
    let country: String
    let style: String
    let nickname: String
    let glassNote: String
    let roast: String
}
```

Simplify the `beer` factory — drop the `file:` parameter entirely:

```swift
    private static func beer(
        _ id: String,
        name: String,
        country: String,
        style: String,
        nickname: String,
        glassNote: String,
        roast: String
    ) -> BeerChoice {
        BeerChoice(id: id, name: name, country: country, style: style,
                   nickname: nickname, glassNote: glassNote, roast: roast)
    }
```

Simplify `worldBeer` the same way:

```swift
    private static func worldBeer(
        _ id: String,
        _ name: String,
        _ country: String,
        _ style: String,
        _ nickname: String,
        _ glassNote: String,
        _ roast: String
    ) -> BeerChoice {
        BeerChoice(id: id, name: name, country: country, style: style,
                   nickname: nickname, glassNote: glassNote, roast: roast)
    }
```

Delete these members entirely: `thumbnailWidth`, `thumbnailPathAllowed`, `commonsImageURL(_:)`, `commonsSourceURL(_:)`, `onlineImageFile(for:style:)`, `fallbackImageFile(for:)`.

Remove the trailing `file: "..."` argument from each of the 6 explicit `beer(...)` call sites — `Puntigamer_beer.jpg`, `Stiegl-bier.jpg`, `Ottakringer_Helles_bottle_with_glass.jpg` and the other three. Find them with:

```bash
grep -n 'file: "' CheekyPint/Features/PintLogging/LogPintSheet.swift
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
xcodebuild test -project CheekyPint.xcodeproj -scheme CheekyPint \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build \
  -only-testing:CheekyPintTests/BeerCatalogTests 2>&1 | grep -E "Executed|error:"
```

Expected: `Executed 4 tests, with 0 failures`.

Note: the build is still red at this point — `BeerCard.beerImage` and `GeneratedBeerArtwork` reference the deleted `imageURL`. Steps 5-8 remove them; the build goes green at Step 9.

- [ ] **Step 5: Delete the photo and confirm-button views**

Remove these declarations entirely from `LogPintSheet.swift`:
- `private var beerImage: some View` and `private var fallbackImage: some View` (inside `BeerCard`)
- `private struct GeneratedBeerArtwork: View` and any `palette` / `fillLevel` / `package` helpers that only it used
- `private struct BeerCard: View` (replaced below)
- `private struct PourToLogButton: View`
- `private var fillToLogSection: some View`
- `private func save() async`
- the `@State private var selectedBeer` line

Keep `PintGlass` — `PintPourView` still uses it.

- [ ] **Step 6: Add the row view**

```swift
/// A single tappable catalog row. The tap is the logging action, so the whole row is a hit
/// target and the label reads as a verb.
private struct BeerRow: View {
    let beer: BeerChoice
    let isLogging: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(beer.name)
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                    Text("\(beer.country) · \(beer.style)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Theme.Spacing.xs)
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.Palette.accent)
            }
            .frame(minHeight: Theme.minTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLogging)
        .accessibilityLabel("Log \(beer.name)")
        .accessibilityHint("\(beer.country), \(beer.style)")
    }
}
```

- [ ] **Step 7: Replace `beerSection` and fold the old sections into `Details`**

```swift
    private var beerSection: some View {
        Section("Tap a beer to log it") {
            TextField("Search the world's beer fridge", text: $beerSearch)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)

            // Form rows are lazy, so all 98 cost nothing until scrolled into view.
            ForEach(filteredBeers) { beer in
                BeerRow(beer: beer, isLogging: isSaving) {
                    Task { await log(beer) }
                }
            }
        }
    }

    /// Everything that used to be its own section. Collapsed by default so the common case is
    /// one tap; whatever is set here applies to the next beer tapped.
    private var detailsSection: some View {
        Section {
            DisclosureGroup("Details", isExpanded: $showDetails) {
                Picker("Size", selection: $serving) {
                    ForEach(ServingType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                if serving == .custom {
                    TextField("Millilitres", text: $customVolume)
                        .keyboardType(.numberPad)
                }
                Toggle("Alcohol-free", isOn: $alcoholFree)
                    .tint(Theme.Palette.accent)
                DatePicker("Time", selection: $occurredAt, in: ...Date(),
                           displayedComponents: [.date, .hourAndMinute])
                TextField("Private note, just for you...", text: $note, axis: .vertical)
                    .lineLimit(1...3)
            }
        } footer: {
            Text("Applies to the next beer you tap.")
        }
    }
```

Add the disclosure state next to the other `@State` properties:

```swift
    @State private var showDetails = false
```

Delete `servingSection` and `noteSection`, and update `body` so the `Form` contains only:

```swift
            Form {
                beerSection
                detailsSection
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(Theme.Palette.warning)
                }
            }
```

- [ ] **Step 8: Add the per-tap logging function**

```swift
    private func log(_ beer: BeerChoice) async {
        guard !isSaving else { return }
        isSaving = true; errorMessage = nil
        defer { isSaving = false }
        // A fresh key per tap. One key per sheet presentation was right when the sheet logged
        // once; now that it can log repeatedly, reusing it would make the second beer look
        // like a retry of the first and be silently discarded.
        let key = IdempotencyKey.generate()
        let volume = serving == .custom ? Double(customVolume) : nil
        let cleanNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let entry = try await container.diary.createPint(
                idempotencyKey: key,
                occurredAt: occurredAt,
                serving: serving,
                volumeMl: volume,
                alcoholFree: alcoholFree,
                pubID: nil,
                sessionID: nil,
                note: BeerCatalog.diaryNote(for: beer, userNote: cleanNote)
            )
            container.analytics.track(.pintSaved)
            Haptics.success()
            dismiss()
            try? await Task.sleep(for: .milliseconds(280))
            await onLogged(entry)
        } catch let error as SupabaseError {
            errorMessage = error.friendlyMessage
        } catch {
            errorMessage = "Couldn't save that beer. Please try again."
        }
    }
```

Delete the now-unused `@State private var idempotencyKey = IdempotencyKey.generate()`.

- [ ] **Step 9: Build and run the full app suite**

```bash
xcodebuild test -project CheekyPint.xcodeproj -scheme CheekyPint \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build \
  -only-testing:CheekyPintTests 2>&1 | grep -E "Executed|error:|BUILD"
```

Expected: build succeeds, `Executed 7 tests, with 0 failures` (3 pre-existing `AppSmokeTests` + 4 new `BeerCatalogTests`).

- [ ] **Step 10: Verify on the simulator**

```bash
xcodebuild -project CheekyPint.xcodeproj -scheme CheekyPint -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build build
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null; xcrun simctl bootstatus "iPhone 17 Pro" -b
xcrun simctl install "iPhone 17 Pro" build/Build/Products/Debug-iphonesimulator/CheekyPint.app
xcrun simctl launch "iPhone 17 Pro" app.cheekypint.CheekyPint.dev -uiTestDemo
```

Then tap *Log a beer*, tap any row, and screenshot to confirm the `+1 succulence` celebration fires and no image placeholders remain:

```bash
xcrun simctl io "iPhone 17 Pro" screenshot /tmp/tap-to-log.png
```

Expected: a text-only beer list, no spinners, one tap logs and shows the celebration.

- [ ] **Step 11: Update the catalog notes**

In `FRIEND_CIRCLE_NOTES.md`, replace lines 42-46 (the paragraph beginning "Image-backed beers load from Wikimedia Commons") with:

```markdown
The catalog is text-only. Beer photos were removed: the Wikimedia Commons images previously used
required visible attribution under CC BY-SA / CC BY (12 of the 15 distinct files), several were
photographs of live commercial brands, and hot-linking Commons breaches their robot policy. Tapping
a row logs that beer immediately; serving size, alcohol-free, time and a private note live behind
the collapsed `Details` disclosure.
```

- [ ] **Step 12: Commit**

```bash
git add CheekyPint/Features/PintLogging/LogPintSheet.swift CheekyPintTests/BeerCatalogTests.swift FRIEND_CIRCLE_NOTES.md
git rm --cached CheekyPintTests/BeerImageURLTests.swift 2>/dev/null || true
git commit -m "feat: log a beer with one tap, drop photo cards"
```

---

### Task 2: Rename the nudge in SQL

**Files:**
- Rename: `supabase/migrations/20260803000000_cheers.sql` → `supabase/migrations/20260803000000_nudges.sql`
- Modify: `supabase/tests/rls_rpc_suite.sql`

**Interfaces:**
- Produces: table `public.nudges`; RPCs `public.send_nudge(p_recipient_id uuid)` and `public.get_received_nudges()`.

- [ ] **Step 1: Rename the file**

```bash
cd ~/Projects/cheekypint
git mv supabase/migrations/20260803000000_cheers.sql \
       supabase/migrations/20260803000000_nudges.sql 2>/dev/null || \
  mv supabase/migrations/20260803000000_cheers.sql \
     supabase/migrations/20260803000000_nudges.sql
```

The migration has never been applied to a hosted database, so renaming in place is safe — no follow-up `alter table ... rename` migration is needed.

- [ ] **Step 2: Rewrite the identifiers**

In `20260803000000_nudges.sql` replace, in this order (longest first, so substrings don't corrupt):

| From | To |
|---|---|
| `get_received_cheers` | `get_received_nudges` |
| `send_cheers` | `send_nudge` |
| `cheers_id` | `nudge_id` (the returned column at line 88 — `NudgeDTO.nudgeId` decodes from it) |
| `cheers_one_unanswered_per_direction_idx` | `nudges_one_unanswered_per_direction_idx` |
| `cheers_recipient_unanswered_idx` | `nudges_recipient_unanswered_idx` |
| `cheers_not_self` | `nudges_not_self` |
| `cheers_send` | `nudge_send` (the `enforce_rate_limit` key) |
| `public.cheers` | `public.nudges` |

Update the two comments to match:

```sql
-- CheekyPint: one-at-a-time, Facebook-Poke-style Nudges between accepted friends.
-- A Nudge is social only: it never changes pint totals or leaderboard rank.
```

```sql
comment on table public.nudges is
  'One-at-a-time social Nudge between friends; never affects drink totals.';
```

Verify nothing was missed:

```bash
grep -in "cheers" supabase/migrations/20260803000000_nudges.sql
```

Expected: no output.

- [ ] **Step 3: Rename in the RLS suite**

```bash
grep -in "cheers" supabase/tests/rls_rpc_suite.sql
```

Apply the same substitutions to every hit, then re-run the grep and expect no output.

- [ ] **Step 4: Run the SQL suite**

```bash
./supabase/tests/run_local_pg.sh
```

Expected: the suite passes, including the renamed nudge cases. If local Postgres is unavailable, note it and move on — Task 4's UI test exercises the demo path, which needs no database.

- [ ] **Step 5: Commit** 

```bash
git add supabase/
git commit -m "refactor: rename cheers table and RPCs to nudges"
```

---

### Task 3: Rename the nudge in the data layer

**Files:**
- Modify: `CheekyPint/Core/Database/RPCContracts.swift`
- Modify: `CheekyPint/Core/Database/FriendsRepository.swift`
- Modify: `CheekyPint/Core/Demo/DemoWorld.swift`

**Interfaces:**
- Consumes: `send_nudge` / `get_received_nudges` from Task 2.
- Produces: `NudgeParams(pRecipientId:)`; `NudgeDTO(nudgeId:senderId:displayName:avatarPath:createdAt:)` with `id == nudgeId`; `FriendsRepository.sendNudge(to:)` and `FriendsRepository.fetchReceivedNudges()`; `DemoWorld.sendNudge(to:)` and `DemoWorld.receivedNudges()`.

- [ ] **Step 1: Rename the DTOs**

In `RPCContracts.swift`:

```swift
struct NudgeParams: Encodable, Sendable { let pRecipientId: UUID }
```

```swift
/// One unanswered Nudge, shown to its recipient until they nudge back.
struct NudgeDTO: Decodable, Sendable, Identifiable {
    let nudgeId: UUID
    let senderId: UUID
    let displayName: String
    let avatarPath: String?
    let createdAt: Date
    var id: UUID { nudgeId }
}
```

No `CodingKeys` are needed: `JSONCoding.swift:9` sets `decoder.keyDecodingStrategy = .convertFromSnakeCase`, so `nudgeId` decodes from the `nudge_id` column that Task 2 renames. This is why Task 2's `cheers_id` → `nudge_id` substitution is mandatory — miss it and this DTO fails to decode at runtime with no compile error.

- [ ] **Step 2: Rename the repository methods**

In `FriendsRepository.swift`:

```swift
    // MARK: Nudges

    /// Send a Facebook-Poke-style Nudge. Only one unanswered Nudge can be waiting in a
    /// direction; nudging back acknowledges the incoming one and sends a fresh one back.
    func sendNudge(to recipientID: UUID) async throws {
        if await DemoWorld.shared.isActive {
            try await DemoWorld.shared.sendNudge(to: recipientID)
            return
        }
        try await data.rpcVoid("send_nudge", params: NudgeParams(pRecipientId: recipientID))
    }

    func fetchReceivedNudges() async throws -> [NudgeDTO] {
        if await DemoWorld.shared.isActive { return await DemoWorld.shared.receivedNudges() }
        return try await data.rpc("get_received_nudges", params: EmptyBody())
    }
```

- [ ] **Step 3: Rename the demo backend**

In `DemoWorld.swift`: `private var cheers: [DemoCheers]` → `private var nudges: [DemoNudge]`, `struct DemoCheers` → `struct DemoNudge`, `sendCheers` → `sendNudge`, `receivedCheers()` → `receivedNudges()`, and the seeded array. Update the user-visible rate-limit copy:

```swift
            throw SupabaseError.rateLimited(hint: "Nudge already sent — wait for your friend to nudge back.")
```

And the seeding comment:

```swift
        // Seed one incoming Nudge so the interaction is immediately visible in demo and
        // friend-circle mode. Sending it back turns it into an outgoing Nudge.
```

- [ ] **Step 4: Confirm the data layer is clean**

```bash
grep -in "cheers" CheekyPint/Core/
```

Expected: no output.

- [ ] **Step 5: Commit** 

```bash
git add CheekyPint/Core/
git commit -m "refactor: rename cheers to nudge in the data layer"
```

---

### Task 4: Rename the nudge in the UI and its test

**Files:**
- Modify: `CheekyPint/Features/Leaderboard/LeaderboardRowView.swift`
- Modify: `CheekyPint/Features/Leaderboard/LeaderboardView.swift`
- Modify: `CheekyPintUITests/OnboardingUITests.swift`

**Interfaces:**
- Consumes: `NudgeDTO`, `sendNudge(to:)`, `fetchReceivedNudges()` from Task 3.
- Produces: `NudgeButtonState` with cases `available`, `received`, `sending`, `sent`; `LeaderboardRowView(..., nudgeState:onNudge:)`.

- [ ] **Step 1: Update the UI test first (it is the regression gate)**

In `OnboardingUITests.swift`:

```swift
    @MainActor
    func testCanNudgeBackFromLeaderboard() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestDemo"]
        app.launch()

        let leaderboardTab = app.tabBars.buttons["Leaderboard"]
        XCTAssertTrue(leaderboardTab.waitForExistence(timeout: 10))
        leaderboardTab.tap()

        let nudgeBack = app.buttons["Nudge back"]
        XCTAssertTrue(nudgeBack.waitForExistence(timeout: 10))
        nudgeBack.tap()

        XCTAssertTrue(app.staticTexts["Nudge sent to Barnaby"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Sent"].exists)
    }
```

- [ ] **Step 2: Run it to verify it fails**

```bash
xcodebuild test -project CheekyPint.xcodeproj -scheme CheekyPint \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build \
  -only-testing:CheekyPintUITests/OnboardingUITests/testCanNudgeBackFromLeaderboard 2>&1 | tail -20
```

Expected: FAIL — the button is still labelled "Cheers back".

- [ ] **Step 3: Rename the row view**

In `LeaderboardRowView.swift`:

```swift
enum NudgeButtonState {
```

with labels:

```swift
        case .available: return "Nudge"
        case .received: return "Nudge back"
```

properties:

```swift
    var nudgeState: NudgeButtonState?
    var onNudge: (() -> Void)?
```

and the button, including its accessibility hints:

```swift
    private var nudgeButton: some View {
        if let nudgeState, let onNudge {
            Button(action: onNudge) {
                Label(nudgeState.label, systemImage: nudgeState.systemImage)
            }
            .tint(nudgeState == .received ? Theme.Palette.accent : Theme.Palette.textSecondary)
            .disabled(nudgeState == .sent || nudgeState == .sending)
            .accessibilityHint(nudgeState == .received
                ? "Sends a Nudge back to this friend"
                : "Sends a Nudge to this friend")
```

Update the `else if cheersState == .received` branch and the `cheersButton` call site to the new names.

- [ ] **Step 4: Rename the leaderboard screen**

In `LeaderboardView.swift` rename the state and copy:

```swift
    @State private var receivedNudges: [UUID: NudgeDTO] = [:]
    @State private var sentNudges: Set<UUID> = []
    @State private var pendingNudges: Set<UUID> = []
    @State private var nudgeConfirmation: String?
    @State private var nudgeError: String?
```

```swift
        .alert("Couldn't send Nudge", isPresented: Binding(
            get: { nudgeError != nil },
            set: { if !$0 { nudgeError = nil } }
```

Rename `cheersState(for:)` → `nudgeState(for:)`, `sendCheers(to:)` → `sendNudge(to:)`, the `incomingCheers`/`incoming` locals, and the row arguments to `nudgeState:` / `onNudge:`. The confirmation string must render exactly `Nudge sent to <name>` to satisfy the test.

- [ ] **Step 5: Run the test to verify it passes**

```bash
xcodebuild test -project CheekyPint.xcodeproj -scheme CheekyPint \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build \
  -only-testing:CheekyPintUITests/OnboardingUITests/testCanNudgeBackFromLeaderboard 2>&1 | grep -E "Executed|error:"
```

Expected: `Executed 1 test, with 0 failures`.

- [ ] **Step 6: Confirm the rename is complete**

```bash
grep -rin "cheers" --include="*.swift" CheekyPint/ CheekyPintTests/ CheekyPintUITests/
```

Expected: **only** `HomeViewModel.swift` (2 hits, `WelfareMonitor.cheersMessage`). Anything else is a miss. `CheekyPintCore` hits are also expected and correct — see Global Constraints.

- [ ] **Step 7: Run every suite**

```bash
cd CheekyPintCore && swift test 2>&1 | tail -3; cd ..
xcodebuild test -project CheekyPint.xcodeproj -scheme CheekyPint \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build 2>&1 | grep -E "Executed|BUILD"
```

Expected: 54 `CheekyPintCore` tests pass; app unit + UI tests pass.

- [ ] **Step 8: Commit** 

```bash
git add CheekyPint/Features/Leaderboard/ CheekyPintUITests/OnboardingUITests.swift
git commit -m "refactor: rename cheers to nudge in the leaderboard UI"
```

---

## Not in this plan

Part B (the feed) is a separate plan: `posts` / `post_cheers` / `post_comments` / `comment_mentions`, the `post-images` bucket, feed RPCs, the four screens, the `MODERATION.md` rewrite, and the new Feed tab in `MainTabView`. Write it once this plan is green.
