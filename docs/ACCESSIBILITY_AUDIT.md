# Accessibility audit — Part 2 feed/moderation/settings surfaces

Closes `RELEASE_CHECKLIST.md:36` for the five screens Part 2 added, plus the two Part 1 files
Part 2 modified. Branch `feat/feed-client`, HEAD `84345c2`.

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
| `PostCommentsSheet` | **Fail (medium).** The comment header packs display name and relative time into one `HStack` (`PostCommentsSheet.swift:157-168`). At XXL, "Barnaby" hyphenates mid-word into "Barn-" / "aby" on two lines while squeezed against "20 min ago" — see §2 finding F1 for the fix comparison. The composer's own `0/280` counter is fine (own line, no collision). The mention-suggestion list renders correctly for the one match available but its `frame(maxHeight: 180)` (`PostCommentsSheet.swift:308`) leaves room for only about one full-height row at this text size — not confirmed to clip a second row since only one friend ("Barnaby") matched "@B" in the seeded demo data. | `/tmp/a11y-comments.png`, `/tmp/a11y-comments-mentions.png` |
| `ReportContentView` | **Fail (high).** The Reason `Picker`'s selected-value text is middle-truncated to `"Inappr…te text"` (full string "Inappropriate text", `Enums.swift:57`) next to the up/down chevron (`ReportContentView.swift:127-134`). Several other category strings are longer still ("Inappropriate profile image", "Inappropriate post photo", "Underage concern" — `Enums.swift:55-61`) and would truncate at least as badly. The `Details (optional)` field and its `0/1000` counter are fine — they stack cleanly with no collision. | `/tmp/a11y-report.png`, `/tmp/a11y-report-details.png` |
| `DataExportView` | **Pass**, with a caveat. All text reflows correctly with no clipping; the long explanatory paragraph and the "Prepare my data export" button just require several screens of scrolling to reach at this text size, which is expected `ScrollView` behaviour, not a bug. Not independently confirmed that the button and `ShareLink` remain reachable by scrolling all the way down (I stopped once the button was off-screen; the content is plain text in a `VStack` inside a `ScrollView`, so nothing suggests it wouldn't be, but I didn't scroll to it and screenshot it directly). | `/tmp/a11y-dataexport.png` |

---

## 2. VoiceOver semantics — top findings

| # | Severity | File:line | Finding | User impact |
|---|---|---|---|---|
| F1 | **High** | `ReportContentView.swift:127-134`; string source `CheekyPintCore/Sources/CheekyPintCore/Models/Enums.swift:53-63` | Same root cause as the Dynamic-Type failure above: the Picker's rendered value is visually truncated at accessibility text sizes. **Unverified:** whether VoiceOver's spoken value for the Picker is also the truncated glyph string or the full underlying string — I could not confirm this without a live VoiceOver session. | If VoiceOver also reads the truncated form, a blind user reporting content cannot tell which category is selected from the summary row alone. Even if VoiceOver reads correctly, a low-vision sighted user relying on large text cannot. |
| F2 | **High** | No occurrence anywhere in the app (`grep -rn "UIAccessibility\|AccessibilityNotification\|postNotification"` over `CheekyPint/Features` and `CheekyPint/Core` returns nothing) | None of the five inline error/success `Text`s — `compose-post-error` (`ComposePostSheet.swift:84-88`), `comments-send-error` (`PostCommentsSheet.swift:76-83`), `report-content-error`/`report-content-sent` (`ReportContentView.swift:156-167`), `data-export-error`/`data-export-warning` (`DataExportView.swift:71-83`) — is ever announced via `UIAccessibility.post(notification:.announcement/.screenChanged, …)` when it appears. SwiftUI does not announce a sibling view's appearance on its own unless focus moves there. | A VoiceOver user who taps Post/Send and hits a failure (rate limit, network error, over-limit) gets no spoken feedback. The error is silent unless they happen to swipe back over that exact row afterward. |
| F3 | **Medium** | `FeedPostCard.swift:142-164` vs. `ComposePostSheet.swift:142-148` | The feed card's own photo (`RemoteImage`, the user's uploaded pint photo) carries no `.accessibilityLabel` and is not `.accessibilityHidden` — it gets whatever default SwiftUI/`Image` gives an unlabeled image (effectively "Image", nothing descriptive). This is inconsistent with the composer's own thumbnail preview of the *same* photo, which is correctly `.accessibilityHidden(true)` (`ComposePostSheet.swift:148`) since "Remove photo" already covers it. | A blind user swiping through the feed hears an uninformative stop for every post that has a photo — no indication a photo exists or what it might show (nothing in the data model carries alt text to draw from, so the honest fix is likely `.accessibilityLabel("Photo attached to this post")` or a hidden/decorative treatment, not a fabricated description). **Trivial fix**: add an explicit label. |
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
| `success` (`ReportContentView`'s "sent" label, `.callout` weight, ~16pt) on `backgroundPrimary` | **3.10:1 — fails** | 8.21:1 | **Fails in light mode** |
| `accent`/AccentGreen (`CheersButton`'s cheered-state text+icon, `.callout.weight(.semibold)`) on `backgroundSecondary` (card) | **3.37:1 — fails 4.5:1**, clears the 3:1 large-text floor | 7.32:1 | **Fails 4.5:1 in light mode**; whether `.callout`+`.semibold` legitimately qualifies as WCAG "large text" (≥18pt regular or ≥14pt bold) is genuinely ambiguous — flagging rather than asserting either way |
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

---

## 5. Gaps — things I could not assess and why

- **`ComposePostSheet`'s photo-thumbnail state at XXL.** Adding a photo requires driving
  `PhotosPicker` (a system `PHPickerViewController`), which I didn't attempt in the UI test. From
  code alone the thumbnail is a fixed `Theme.Sizing.photoPreview` (160pt) frame independent of
  Dynamic Type (`Theme.swift:50-52`, `ComposePostSheet.swift:142-148`), so it shouldn't reflow
  badly, but I have no screenshot of it.
- **Whether VoiceOver's spoken value for the truncated Reason `Picker` is also truncated** (F1) —
  needs a live VoiceOver session to confirm either way.
- **Whether the Reason `Picker` is still fully operable (opens, lets you pick a category) at
  accessibility XXL.** My UI test's attempt to tap it open produced an inconclusive result in an
  earlier run (identical screenshots before/after the tap), and rather than keep debugging a
  throwaway test I dropped that step. This should be manually verified before submission — it's a
  hard requirement (Send is disabled until a valid state exists, and category selection is the only
  way to change it).
- **Mention-suggestion list overflow with more than one match.** The seeded demo data only produces
  one friend match ("Barnaby") for "@B", so I couldn't observe whether a second/third suggestion row
  is reachable only by scrolling (no visible cue) inside the `frame(maxHeight: 180)` container
  (`PostCommentsSheet.swift:308`) at accessibility XXL.
- **Error-state screens at XXL.** No error was triggered during this pass (all network calls
  succeeded in demo mode), so I didn't get a screenshot of e.g. `compose-post-error` or
  `data-export-error` rendered at accessibility XXL. These are plain wrapping `Text` views with no
  fixed-height container, so code inspection suggests low risk, but this wasn't directly observed.
- **`DataExportView` reachability of the "Prepare" button by scrolling all the way down at XXL** —
  inspected only as far as the button going off-screen; didn't scroll further to screenshot it in
  view.
