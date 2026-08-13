# Accessibility audit — Part 2 feed/moderation/settings surfaces

Closes `RELEASE_CHECKLIST.md:36` for the five screens Part 2 added, plus the two Part 1 files
Part 2 modified. Branch `feat/feed-client`, HEAD `84345c2`.

**Follow-up pass (branch `feat/feed-client`, from HEAD `9d03772`): all six items below — the four
findings and the two "could not assess" gaps — are now fixed/closed.** See §6 for what changed,
the recomputed contrast ratios, and the re-screenshot evidence, including two real defects this
pass's own screenshots caught that the original code-review-only pass had guessed were low-risk
(they weren't). The sections below are left as the original record; each affected row/finding now
carries a "**Status (follow-up):**" line rather than being rewritten.

**Scope:** `ComposePostSheet.swift`, `PlacePickerSheet.swift`, `PostCommentsSheet.swift`,
`ReportContentView.swift`, `DataExportView.swift`, `FeedView.swift`, `FeedPostCard.swift`.

**Method.**
- *Dynamic Type:* a throwaway UI test (deleted after this pass; not in the diff) launched with
  `-uiTestDemo -UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXXL`,
  navigated to each surface, and wrote screenshots to `/tmp/a11y-*.png`. Every screenshot below
  was opened and visually inspected, not inferred from the test passing.
- *VoiceOver:* static code review — every `Text`/`Image`/`Button` on the seven files was checked
  for a label, a trait, and (for images) whether it's decorative or meaningful. No live VoiceOver
  session was run (no way to drive VoiceOver's actual speech output from this environment), so
  claims about what VoiceOver *announces* are inferred from the accessibility tree/API contract,
  not observed speech.
- *Reduce Motion:* grep for `animation`/`transition`/`accessibilityReduceMotion` across the seven
  files.
- *Contrast:* the four colours these screens actually use (`textSecondary`, `warning`, `success`,
  `accent`) are backed by the asset catalog's `Contents.json`, which stores literal sRGB hex
  components for both appearances — not a value SwiftUI computes at runtime. Ratios below are
  computed directly from those numbers (WCAG relative-luminance formula), not eyeballed from a
  screenshot.

---

## 1. Dynamic Type at accessibility XXL

| Screen | Verdict | Evidence |
|---|---|---|
| Feed list (`FeedPostCard`) | **Pass.** Author name and relative time stack vertically (`FeedPostCard.swift:49-60`), so both get the full row width; the place label wraps onto two lines cleanly; no clipping, no horizontal scroll. | `/tmp/a11y-feed.png` |
| `ComposePostSheet` | **Pass** for the states exercised. Body field, `0/500` counter, Photo section, and "Add a location" row all reflow onto their own lines with no clipping or collision. **Not exercised:** the photo-thumbnail state (adding a photo requires driving `PhotosPicker`, which I didn't attempt) — see gaps. | `/tmp/a11y-compose.png` |
| `PlacePickerSheet` | **Pass.** Typed-text row, the "Use "London"" button, and a resolved `MKLocalSearchCompleter` result ("London / England") all wrap onto multiple lines without truncation; nothing is clipped by the keyboard beyond normal scrollable overflow. | `/tmp/a11y-placepicker.png`, `/tmp/a11y-placepicker-typed.png` |
| `PostCommentsSheet` | **Fail (medium).** The comment header packs display name and relative time into one `HStack` (`PostCommentsSheet.swift:157-168`). At XXL, "Barnaby" hyphenates mid-word into "Barn-" / "aby" on two lines while squeezed against "20 min ago" — see §2 finding F1 for the fix comparison. The composer's own `0/280` counter is fine (own line, no collision). The mention-suggestion list renders correctly for the one match available but its `frame(maxHeight: 180)` (`PostCommentsSheet.swift:308`) leaves room for only about one full-height row at this text size — not confirmed to clip a second row since only one friend ("Barnaby") matched "@B" in the seeded demo data. **Status (follow-up): fixed.** Header changed from `HStack` to `VStack(alignment: .leading, spacing: Theme.Spacing.xxs)` (matching `FeedPostCard.header`'s own layout exactly), one line each for name and time — no hyphenation. Re-screenshotted with the keyboard up and mid-mention-autocomplete; "Barnaby" / "20 min ago" render as two clean lines. The 2-match mention-list gap is closed in §6 below (both "Barnaby" and "Ceri" render simultaneously, no clipping, when querying "@" alone). | `/tmp/a11y-comments.png`, `/tmp/a11y-comments-mentions.png` (original); see §6 for follow-up screenshots |
| `ReportContentView` | **Fail (high).** The Reason `Picker`'s selected-value text is middle-truncated to `"Inappr…te text"` (full string "Inappropriate text", `Enums.swift:57`) next to the up/down chevron (`ReportContentView.swift:127-134`). Several other category strings are longer still ("Inappropriate profile image", "Inappropriate post photo", "Underage concern" — `Enums.swift:55-61`) and would truncate at least as badly. The `Details (optional)` field and its `0/1000` counter are fine — they stack cleanly with no collision. **Status (follow-up): fixed.** `.pickerStyle(.navigationLink)` replaces the Form default. The collapsed summary row now shows the full string wrapped onto two lines ("Inappropriate" / "text", "Underage" / "concern" — no ellipsis anywhere), and the destination screen lists every category at full length, each free to wrap (one case, "Impersonation", hyphenates across two lines — a normal line-break, not a truncation: no character is lost, unlike the original mid-word ellipsis). Operability and VoiceOver-value gaps (both previously unassessed) are closed in §6. | `/tmp/a11y-report.png`, `/tmp/a11y-report-details.png` (original); see §6 for follow-up screenshots |
| `DataExportView` | **Pass**, with a caveat. All text reflows correctly with no clipping; the long explanatory paragraph and the "Prepare my data export" button just require several screens of scrolling to reach at this text size, which is expected `ScrollView` behaviour, not a bug. Not independently confirmed that the button and `ShareLink` remain reachable by scrolling all the way down (I stopped once the button was off-screen; the content is plain text in a `VStack` inside a `ScrollView`, so nothing suggests it wouldn't be, but I didn't scroll to it and screenshot it directly). | `/tmp/a11y-dataexport.png` |

---

## 2. VoiceOver semantics — top findings

| # | Severity | File:line | Finding | User impact |
|---|---|---|---|---|
| F1 | **High** | `ReportContentView.swift:127-134`; string source `CheekyPintCore/Sources/CheekyPintCore/Models/Enums.swift:53-63` | Same root cause as the Dynamic-Type failure above: the Picker's rendered value is visually truncated at accessibility text sizes. **Unverified:** whether VoiceOver's spoken value for the Picker is also the truncated glyph string or the full underlying string — I could not confirm this without a live VoiceOver session. | If VoiceOver also reads the truncated form, a blind user reporting content cannot tell which category is selected from the summary row alone. Even if VoiceOver reads correctly, a low-vision sighted user relying on large text cannot. **Status (follow-up): fixed, and the "unverified" gap closed as far as this environment allows.** `.pickerStyle(.navigationLink)` (same fix as §1). The unverified half is closed by reading the picker element's own `.value` through `XCUITest` (a real accessibility-tree read, not code review): after switching category, `reasonRow.value` reports the exact string `"Underage concern"` — the full text, not a truncated form — which is what VoiceOver's value-speaking is contractually built from. A live VoiceOver *audio* session still wasn't run (same tooling limit as the first pass), but this is materially stronger evidence than static code review. |
| F2 | **High** | No occurrence anywhere in the app (`grep -rn "UIAccessibility\|AccessibilityNotification\|postNotification"` over `CheekyPint/Features` and `CheekyPint/Core` returns nothing) | None of the five inline error/success `Text`s — `compose-post-error` (`ComposePostSheet.swift:84-88`), `comments-send-error` (`PostCommentsSheet.swift:76-83`), `report-content-error`/`report-content-sent` (`ReportContentView.swift:156-167`), `data-export-error`/`data-export-warning` (`DataExportView.swift:71-83`) — is ever announced via `UIAccessibility.post(notification:.announcement/.screenChanged, …)` when it appears. SwiftUI does not announce a sibling view's appearance on its own unless focus moves there. | A VoiceOver user who taps Post/Send and hits a failure (rate limit, network error, over-limit) gets no spoken feedback. The error is silent unless they happen to swipe back over that exact row afterward. **Status (follow-up): fixed.** New `AccessibilityAnnouncer` (`CheekyPint/Core/Utilities/AccessibilityAnnouncer.swift`) calls `UIAccessibility.post(notification: .announcement, argument:)` from an `.onChange` on each of the five messages, and dedups against the *last spoken text* (not just "did the value change") so retrying into the identical error twice doesn't nag — see `AccessibilityAnnouncerTests.swift` (9 unit tests) for the dedup behaviour, spied via an injected `post` closure rather than the real API. Screenshotting the offline-error path also caught and fixed a real, independent defect (see §6). |
| F3 | **Medium** | `FeedPostCard.swift:142-164` vs. `ComposePostSheet.swift:142-148` | The feed card's own photo (`RemoteImage`, the user's uploaded pint photo) carries no `.accessibilityLabel` and is not `.accessibilityHidden` — it gets whatever default SwiftUI/`Image` gives an unlabeled image (effectively "Image", nothing descriptive). This is inconsistent with the composer's own thumbnail preview of the *same* photo, which is correctly `.accessibilityHidden(true)` (`ComposePostSheet.swift:148`) since "Remove photo" already covers it. | A blind user swiping through the feed hears an uninformative stop for every post that has a photo — no indication a photo exists or what it might show (nothing in the data model carries alt text to draw from, so the honest fix is likely `.accessibilityLabel("Photo attached to this post")` or a hidden/decorative treatment, not a fabricated description). **Trivial fix**: add an explicit label. **Status (follow-up): fixed, decision = label, not hide.** The photo is the *content* of a photo post — hiding it tells a blind user nothing about what they're cheering, and a label naming it as the author's photo (`"Photo posted by \(displayName)"`) is more honest than silence, even though the image itself can't be described from any data this app stores. The composer's own thumbnail correctly stays hidden, and that asymmetry is deliberate: there, the user just picked the photo themselves, so a label would tell them nothing new. Verified via `XCUITest` querying `app.images` for a label matching `"Photo posted by "` — found on Barnaby's seeded photo post. |
| F4 | Low (positive) | `FeedPostCard.swift:225-251` | Contrary to what a bare mug icon might suggest, `CheersButton` already announces state correctly: label is `"Cheered, 1 cheer"` when active vs. `"1 cheer"`/`"N cheers"` when not (lines 247-250), plus a hint ("Cheers this post" / "Removes your cheer from this post", line 244). | No action needed — flagging so this isn't miscounted as a gap. The *visible* label text always reads `"N Cheers"` regardless of count (line 234, e.g. "1 Cheers"), which is a grammar nit on the sighted label, not a VoiceOver defect (the spoken label is correctly singular/plural). |
| F5 | Low | `PostCommentsSheet.swift:156-179` vs. `FeedPostCard.swift:46-64` | Comments get this right: `.accessibilityElement(children: .combine)` merges avatar/name/time/body into one VoiceOver stop while deliberately excluding the trailing menu button (comment at lines 174-176 explains why). `FeedPostCard`'s header has no equivalent grouping — name and time are two separate stops before the menu button. Not broken (all info is still reachable), just an inconsistency; multi-stop cards are also a normal, common VoiceOver pattern for feeds. | Slightly more swiping to get through a feed card than a comment row; no information is lost. |
| — | Low | `PostCommentsSheet.swift:128-133`, `ComposePostSheet.swift:128-133`, `ReportContentView.swift:149-154` | Character counters are not `.accessibilityHidden`; each is its own swipe stop with a full-sentence label ("12 of 500 characters used"). I could not verify at runtime whether this becomes "noise on every keystroke" — no code path re-announces it on change (no notification, and it isn't the focused/typing element), so by default VoiceOver would only speak it if the user explicitly swipes to it, not automatically while typing. Flagging as a design question for a human to confirm live, not a confirmed defect. | Possible: none, if my read of SwiftUI's default announcement behaviour is right. Possible: minor noise, if I'm wrong and something in the focus chain re-triggers it. |

**Things checked and found fine, not called out further:** every icon-only button on all seven files (post/comment overflow menus, `PhotosPicker` trigger, comment send, cancel/close toolbar buttons) has an explicit `.accessibilityLabel` distinct from a bare SF Symbol name; `RemoteAvatar` is unconditionally `.accessibilityHidden(true)` (`RemoteAvatar.swift:27`) so every avatar in the app is consistently decorative; every text field (`compose-post-body`, `place-search-field`, `comment-body-field`, `report-content-details`) has a persistent `.accessibilityLabel` independent of its placeholder.

---

## 3. Reduce Motion

Only one animation exists across all seven files: `CheersButton`'s scale effect
(`FeedPostCard.swift:230, 238-239`), and it correctly branches on
`@Environment(\.accessibilityReduceMotion)` — both the `.scaleEffect` and the `.animation` collapse
to a no-op when Reduce Motion is on. No other animation, transition, or implicit-animation trigger
exists anywhere in `ComposePostSheet`, `PlacePickerSheet`, `PostCommentsSheet`, `ReportContentView`,
`DataExportView`, or `FeedView` — confirmed by grep for
`animation|transition|withAnimation|reduceMotion` across all seven files. This is a valid "nothing
to do" finding for six of the seven files.

---

## 4. Contrast

Colours are defined numerically as sRGB hex triples in
`CheekyPint/Resources/Assets.xcassets/*.colorset/Contents.json` (one entry for light, one tagged
`appearance: dark`) — not opaque asset-catalog blobs — so these ratios are computed directly from
those values via the WCAG relative-luminance formula, not estimated from screenshots. Restricted to
the colours these seven files actually use (`Theme.swift:10-23` for the token → asset name mapping):

| Pair (as used) | Light | Dark | AA body text (4.5:1)? |
|---|---|---|---|
| `textSecondary` on `backgroundPrimary` (captions, place labels, timestamps) | 4.98:1 | 8.55:1 | Pass both |
| `textSecondary` on `backgroundSecondary` (card/composer backgrounds) | 5.40:1 | 7.62:1 | Pass both |
| `textPrimary` on `backgroundPrimary`/`backgroundSecondary` | 14.9–16.1:1 | 14.0–15.7:1 | Pass both |
| `warning` (error text, all four inline-error `Text`s) on `backgroundPrimary`/`backgroundSecondary` | 5.01 / 5.44:1 | 5.45 / 4.86:1 | Pass both |
| `success` (`ReportContentView`'s "sent" label, `.callout` weight, ~16pt) on `backgroundPrimary` | ~~3.10:1 — fails~~ → **4.63:1 — passes** (follow-up) | 8.21:1 (unchanged) | Pass both |
| `accent`/AccentGreen (`CheersButton`'s cheered-state text+icon, `.callout.weight(.semibold)`) on `backgroundSecondary` (card) | ~~3.37:1 — fails 4.5:1~~ → **4.65:1 — passes** (follow-up) | 7.32:1 (unchanged) | Pass both |
| `forest`/ForestGreen (mention highlight in comment bodies) on `backgroundPrimary` | 6.00:1 | 7.31:1 | Pass both |

`beer`/AccentAmber is not used anywhere in these seven files (confirmed by grep), so it's out of
this audit's scope — but for awareness, it measures 2.72:1 against `backgroundPrimary` in light
mode, which fails even the 3:1 large-text floor, should it ever be reused here.

**Concrete findings:**
- **Medium** — `ReportContentView.swift:156-161`, "Thanks — our team will take a look." at
  `Theme.Typography.callout` in `Theme.Palette.success`: 3.10:1 in light mode, below the 4.5:1 body
  text threshold. A low-vision user in light mode may not be able to read the confirmation that
  their report was sent.
- **Low/ambiguous** — `FeedPostCard.swift:237` (cheered-state colour): 3.37:1 in light mode against
  the card background. Below 4.5:1; whether it clears the large-text 3:1 exception depends on
  whether `.semibold` at `.callout` size counts as "bold" for WCAG's purposes, which I'm not
  confident asserting either way.

**Status (follow-up): both fixed, light mode only, dark mode untouched.** `Success.colorset` and
`AccentGreen.colorset` (previously identical hex values, `#12A150` light / `#33C878` dark — one
semantic "done" colour, one semantic "brand action" colour, that happened to share a value) each
had their **light-mode** entry darkened in place, holding hue and saturation constant (an HSL
lightness-only reduction, so both read as the same green family, just a shade deeper — this is a
legibility fix, not a rebrand):
- `Success` light: `#12A150` → `#0E8040`. `success` on `backgroundPrimary`: 3.10:1 → **4.63:1**.
  Also checked against `backgroundSecondary` (not this screen's actual pairing, but for
  completeness): 5.02:1.
- `AccentGreen` light: `#12A150` → `#0F8643`. `accent` (cheered state) on `backgroundSecondary`:
  3.37:1 → **4.65:1**. Also checked against `backgroundPrimary`: 4.29:1 (also now clears 4.5:1,
  though not the pairing this finding was about).
- Dark-mode entries (`#33C878` for both) are byte-for-byte unchanged; their ratios (8.21:1,
  7.32:1) are identical to the original numbers above.
- `AccentGreen` backs `Theme.Palette.accent`, used well beyond these seven files (buttons, tints,
  progress indicators app-wide) — there is only one asset behind that token, so the fix is
  necessarily global in light mode, not scoped to `CheersButton`. The change is a ~15% lightness
  reduction, chosen to be the smallest darkening that clears 4.5:1 with a small margin after hex
  quantization; it should not read as a different brand colour anywhere else it's used.
- Re-screenshotted at accessibility XXL: `07-report-sent-xxl` shows "Thanks — our team will take a
  look." in the new green, fully legible, three lines, no clipping (see §6 for why it also had to
  move to the top of the Form to be visible at all before the screen auto-dismisses).

---

## 5. Gaps — things I could not assess and why

- **`ComposePostSheet`'s photo-thumbnail state at XXL.** Adding a photo requires driving
  `PhotosPicker` (a system `PHPickerViewController`), which I didn't attempt in the UI test. From
  code alone the thumbnail is a fixed `Theme.Sizing.photoPreview` (160pt) frame independent of
  Dynamic Type (`Theme.swift:50-52`, `ComposePostSheet.swift:142-148`), so it shouldn't reflow
  badly, but I have no screenshot of it. **Still unassessed after the follow-up pass** — driving
  the system photo picker from an automated UI test remains out of reach in this environment; not
  attempted again, stated here rather than dropped.
- **Whether VoiceOver's spoken value for the truncated Reason `Picker` is also truncated** (F1) —
  needs a live VoiceOver session to confirm either way. **Closed (as far as this environment
  allows) — see §6.1.** The picker is fixed (no longer truncated), and its exposed `.value` in the
  accessibility tree — what VoiceOver's value-speaking is contractually built from — was confirmed
  to be the full string. A live spoken-audio session still wasn't run; that specific limit stands.
- **Whether the Reason `Picker` is still fully operable (opens, lets you pick a category) at
  accessibility XXL.** My UI test's attempt to tap it open produced an inconclusive result in an
  earlier run (identical screenshots before/after the tap), and rather than keep debugging a
  throwaway test I dropped that step. This should be manually verified before submission — it's a
  hard requirement (Send is disabled until a valid state exists, and category selection is the only
  way to change it). **Closed — see §6.1.** Fully operable: opening the picker, selecting a
  different category, and confirming the value actually changed (and to the *correct* new value)
  all verified via a scripted UI test.
- **Mention-suggestion list overflow with more than one match.** The seeded demo data only produces
  one friend match ("Barnaby") for "@B", so I couldn't observe whether a second/third suggestion row
  is reachable only by scrolling (no visible cue) inside the `frame(maxHeight: 180)` container
  (`PostCommentsSheet.swift:308`) at accessibility XXL. **Closed — see §6.2.** `"@"` alone (empty
  token) matches every friend (`PostCommentsViewModel.suggestions(for:)`'s documented behaviour),
  so both "Barnaby" and "Ceri" are reachable in the seeded demo world. At XXL both rows render
  simultaneously inside the 180pt-max-height list, fully visible, no clipping observed.
- **Error-state screens at XXL.** No error was triggered during this pass (all network calls
  succeeded in demo mode), so I didn't get a screenshot of e.g. `compose-post-error` or
  `data-export-error` rendered at accessibility XXL. These are plain wrapping `Text` views with no
  fixed-height container, so code inspection suggests low risk, but this wasn't directly observed.
  **Closed — see §6.3 — and the "low risk" guess was wrong.** A new `#if DEBUG`
  `-uiTestForceOffline` launch-argument hook (mirroring `-uiTestDemo`'s own pattern) makes
  `FeedRepository.addComment` throw `SupabaseError.offline` deterministically, without touching the
  simulator's real network. Screenshotting the resulting `comments-send-error` at XXL found it
  **genuinely ellipsis-truncated** — "You're offline. We'll try again when yo…" — because its
  `VStack` sibling (`commentsList`) is flexible and the keyboard was visible, leaving less height
  than the full 3-line message needed. Fixed with `.fixedSize(horizontal: false, vertical: true)`,
  applied to all five inline error/success texts defensively (only one was confirmed to actually
  fail, but the fix is free where it isn't needed).
- **`DataExportView` reachability of the "Prepare" button by scrolling all the way down at XXL** —
  inspected only as far as the button going off-screen; didn't scroll further to screenshot it in
  view. **Still unassessed after the follow-up pass** — out of the six items this pass was scoped
  to fix; not re-checked, stated here rather than dropped.

---

## 6. Follow-up pass — method, evidence, and what it changed

Same discipline as the original pass, strengthened where the tooling allowed: every screenshot
below was captured by a scripted `XCUITest` (deleted after this pass, matching the original
method — not in the diff), exported from the `.xcresult` bundle via
`xcrun xcresulttool export attachments`, and opened and read as an image, not inferred from the
test passing. Additionally, several claims that the first pass could only infer from code
(the Reason picker's spoken *value*, the feed photo's *label*) were instead read directly off the
live accessibility tree via `XCUIElement.value`/`.label` — a real, if not audible, VoiceOver-data
read, one rung up from static code review.

**6.1 — Reason picker (Findings 1/F1).** `ReportContentView.swift` — `.pickerStyle(.navigationLink)`
added to the `Picker`. Screenshots: collapsed summary row shows "Inappropriate text" wrapped onto
two full lines (no ellipsis); the destination list shows all seven categories at full length,
including "Inappropriate profile image" and "Underage concern". Operability: scripted picking of
"Underage concern" changed the summary row's value from "Inappropriate text" to "Underage concern"
— confirmed via `XCUIElement.value`, which also confirms the *exact full string* is what's exposed
to the accessibility tree (VoiceOver's value-speaking reads from the same place). `ReportCategory
.displayName` strings themselves are untouched, per the brief.

**6.2 — Comment header + mention list (Finding 2 / gap).** `PostCommentsSheet.swift` — the
name+time `HStack` became a `VStack(alignment: .leading, spacing: Theme.Spacing.xxs)`, textually
identical to `FeedPostCard.header`'s own layout. Screenshot: "Barnaby" and "20 min ago" render as
two clean lines, no hyphenation. Separately, typing `"@"` alone into the comment composer surfaced
both seeded friends ("Barnaby" and "Ceri") simultaneously inside the `frame(maxHeight: 180)`
suggestion list at XXL — both fully visible, nothing clipped.

**6.3 — VoiceOver announcements (Finding 3 / F2).** New `AccessibilityAnnouncer`
(`CheekyPint/Core/Utilities/AccessibilityAnnouncer.swift`), wired via `.onChange` into
`ComposePostSheet` (`errorMessage`), `PostCommentsSheet` (`model?.sendError`), `ReportContentView`
(`errorMessage` and `sent`), and `DataExportView` (`errorMessage` and the truncation warning).
Dedups against the *last spoken text*, not just "did the value change", so retrying into an
identical error twice announces once, not twice, while a genuinely different message (or the same
message recurring after a different one) still announces — 9 unit tests in
`AccessibilityAnnouncerTests.swift` cover this via an injected `post` spy (no live VoiceOver
session; that limit from the first pass stands).

Building the forced-offline path to exercise this surfaced two real, independent defects the
original code-review pass had guessed were low-risk and weren't:
- `PostCommentsSheet`'s `comments-send-error` rendered **ellipsis-truncated** at XXL with the
  keyboard visible ("You're offline. We'll try again when yo…") — its `VStack` sibling
  (`commentsList`) is flexible and absorbed the height the message needed. Fixed with
  `.fixedSize(horizontal: false, vertical: true)`, applied to all five inline texts.
- `ReportContentView`'s "sent" confirmation sat at the *bottom* of the `Form`, below sections that
  alone exceed one screen's height at XXL — meaning it rendered entirely below the fold, and the
  screen auto-dismisses ~1s after appearing, nowhere near enough time to scroll down and see it.
  Moved to the top of the `Form`, matching `ComposePostSheet`'s existing placement of its own
  status text. Re-screenshotted: now visible immediately, no scrolling, at any text size.

**6.4 — Feed photo label (Finding 4 / F3).** `FeedPostCard.swift` — the success-phase `Image` gets
`.accessibilityLabel("Photo posted by \(post.post.displayName)")`. Decision: label, not hide — the
photo is the post's content, and a blind user is entitled to know a photo exists even though this
app has no alt text to describe what's in it. Verified via `XCUIElement` query for an `image` whose
label begins "Photo posted by" — found on Barnaby's seeded photo post. The composer's own
thumbnail preview stays `.accessibilityHidden` unchanged; that asymmetry is intentional (see the
inline comment for the reasoning) and not revisited.

**6.5 — Contrast (Finding 5).** See §4 above for the full numbers. Summary: `success` on
`backgroundPrimary` 3.10:1 → 4.63:1; `accent` on `backgroundSecondary` 3.37:1 → 4.65:1. Light mode
only; dark mode's `#33C878` is untouched and still passes (8.21:1 / 7.32:1).

**6.6 — Offline send + 2-match mentions (Finding 6).** Both closed; see the gap entries in §5
above (now marked closed) and 6.2/6.3 for the mechanics and the defects the exercise uncovered.

**Verification.** `xcodebuild test` (iPhone 17 simulator, `iOS 17.0` floor, Swift 6 strict
concurrency) — CheekyPintTests 128/128 (119 baseline + 9 new `AccessibilityAnnouncerTests`),
CheekyPintUITests 5/5 (unchanged; the throwaway UI test used to gather the evidence above was
deleted after use, per this project's own established method). `swift test` (CheekyPintCore)
77/77, unchanged. `swift run corecheck` 65/65, unchanged. `supabase/tests/run_local_pg.sh` 93/93
SQL assertions, unchanged. Zero failures, zero regressions against the `9d03772` baseline.

**Disagreements / things deliberately not done, for the record.**
- The audit's suggestion to try `.menu` as an alternative `pickerStyle` wasn't needed —
  `.navigationLink` measurably solved the truncation on the first attempt, confirmed by screenshot,
  so `.menu` was never tried.
- `ReportContentView`'s "sent" confirmation being unreachable-in-time at XXL (6.3) is not one of
  the six assigned items; it was fixed anyway (a two-line reorder, matching an existing sibling
  pattern) because leaving Finding 5's contrast fix in place on text a sighted XXL user structurally
  can't see in time would have made that fix moot in practice.
- `AccentGreen`'s light-mode darkening is necessarily app-wide (one asset backs `Theme.Palette
  .accent`, used well beyond `CheersButton`), not scoped to the cheered state alone — flagged in §4
  rather than treated as an unstated side effect.
- `ComposePostSheet`'s photo-thumbnail-at-XXL and `DataExportView`'s scroll-to-`Prepare`-button gaps
  from the original pass remain unassessed — out of this pass's scope (the six named items), not
  silently dropped.
