# State audit — empty / error / offline / permission-denied

Closes `docs/RELEASE_CHECKLIST.md:59` ("Error/empty/offline/permission-denied states verified
on each screen", Quality gates section — App Review expectation; the task that commissioned this
audit cited line 38, which in the current file is a Moderation-section item about the support
address. That line-38 reference is stale; the line-59 item is the one this document closes).
Branch `feat/feed-client`, base HEAD `6243ee4`.

**Status: all three findings below are fixed** (base HEAD for the fix pass: `7c3f220`, 140 app
tests / 77 CheekyPintCore / 65 corecheck / 114 SQL / 5-of-5 UI tests, zero failures). See "Fixes
applied (follow-up pass)" for what changed, the real root cause of the Cheers alert (not the
two-`.alert` hypothesis that motivated the fix pass), and final test counts.

**Update (tap-routing pass, base HEAD `b7f4e85`): the "Cheers can spuriously open Comments" defect
logged at the end of "Fixes applied" §1 below is now fixed too, and fixing it required correcting
§1's own root-cause finding.** The "whether the tap passes through a native
`Menu`/`confirmationDialog` transition first" conclusion in §1 was a real, reproducible
correlation but not the actual mechanism — it was never re-tested against button style, because at
the time nobody suspected `FeedPostCard.footer`'s two plain, unstyled `Button`s of anything beyond
being the tap targets. They were the actual cause of both symptoms. See the corrected §1 write-up
below and the new §4 for the fix, the elimination evidence, and the controlled experiment that
proves the correction (reverting to the original live-read `.alert` shape, on top of the button-
style fix alone, makes it present reliably — see §4).

**Update (photo tap-target pass, base HEAD `261a223`): a third tap-routing defect in this same
`List` row.** `FeedPostCard`'s new photo `Button` — added in `261a223`, and added *carefully*, with
the `.buttonStyle(.plain)` §4 established — had a tap target 2.25× the size of the picture it
draws, because `.clipShape` clips drawing but not hit testing. See §5 for the mechanism, why the UI
test that shipped alongside the feature passed against it, and the fix. The presentations scattered
across that row's subviews were hoisted to one place at the same time.

**Screens:** `FeedView`/`FeedPostCard`, `ComposePostSheet`, `PlacePickerSheet`,
`PostCommentsSheet`, `ReportContentView`, `DataExportView`.

**Method.** A `#if DEBUG` fault-injection seam, `DebugFaultInjector`
(`CheekyPint/Core/Utilities/DebugFaultInjector.swift`), lets a UI test force any of 14 repository
operations to throw a specific `SupabaseError`, force a read to return empty, or both — driven
entirely by launch arguments, with demo mode (`-uiTestDemo`) supplying deterministic seed data
underneath. A throwaway UI test, `CheekyPintUITests/StateAuditUITests.swift` (written by a
previous pass, extended here, **removed after this audit** — see the "regression suite or
throwaway" decision at the end of this document), drove each screen into each reachable state and
wrote a screenshot to `/tmp/state-<screen>-<state>.png`. Every screenshot cited below was opened
and read as an image, not inferred from the test passing — this project shipped a card that
overflowed the screen width with every test green, so "the test ran" is not evidence on its own.

Where a state could not be driven at all, the table says so explicitly and reasons from the code
instead of fabricating a screenshot.

---

## The Cheers finding, precisely

The interrupted pass's own test named `/tmp/state-feed-cheers-error-silent-failure.png`
"silent failure", and a screenshot of it alone shows Alice's post rendering as cheered ("2
Cheers", filled green mug) with no error visible anywhere on screen after a forced `toggleCheers`
failure. Read in isolation that looks like "the app shows the user cheered when the write
failed" — the worst-case version of this bug. It is not that. Here is what actually happens,
established from the code and confirmed with a second, unambiguous screenshot-plus-assertion:

- **The optimistic update does roll back on the throw path**, distinctly from the
  reconcile-from-response success path. `FeedViewModel.toggleCheers` (`FeedViewModel.swift:264-285`)
  flips `viewerHasCheered`/`cheersCount` optimistically (lines 270-273), then either reconciles
  from the server's real response on success (line 277) or, in the `catch let error as
  SupabaseError` / generic `catch` blocks (lines 278-283), calls
  `reconcile(postID:, cheered: previousCheered, cheersCount: previousCount)` — i.e. it explicitly
  restores the **pre-tap** values, not the optimistic guess. The throw path is handled, and
  handled differently from the mismatched-response path (there is no mismatched-response path;
  the server response is always trusted verbatim on success).
- **"2 Cheers" was the pre-existing seeded value, not the optimistic increment.** Alice's own
  post is seeded already cheered: `DemoWorld.swift:150-153` — `post(30, author: aliceID, ...,
  cheers: 2, cheered: true)`. Tapping it optimistically *decrements* to 1/uncheered, the fault
  fires, and the rollback restores exactly 2/cheered — the value the screenshot shows is the
  correct rolled-back state, coincidentally identical to the untouched one, not a stuck wrong
  value.
- **To remove any doubt, a second test targets Barnaby's post** (index 1), seeded at
  zero/uncheered (`DemoWorld.swift:154-156`, no `cheers:`/`cheered:` args — the declared
  defaults). `testFeedCheersErrorRollsBackOnAnUncheeredPost` asserts the accessibility label
  (`FeedPostCard.swift:256-259`) reads `"0 cheers"` **before** the tap, taps, waits, and asserts it
  reads `"0 cheers"` again — not the optimistic `"Cheered, 1 cheer"`. **This assertion passed.**
  Screenshot: `/tmp/state-feed-cheers-error-rollback-uncheered.png` — Barnaby's card shows "0
  Cheers", grey, un-cheered, matching the assertion.
- **What actually is broken, confirmed by both screenshots: no error is surfaced at all.**
  `cheersError` is set correctly to the friendly message every time (line 280/283), but
  `FeedView`'s `.alert("Couldn't update Cheers", …)` (`FeedView.swift:106-113`) never presents —
  the previous pass confirmed this directly by temporarily instrumenting `toggleCheers` and
  observing `cheersError` hold the correct string while no alert appeared, even after an unrelated
  re-render (switching tabs away and back). This is specific to Cheers: the sibling `deleteError`
  alert (`FeedView.swift:114-121`, identical `.alert` shape) **does** present — confirmed by
  `testFeedDeleteErrorAlert`, screenshot `/tmp/state-feed-delete-error.png` — so the defect is not
  "alerts never work in this view", it is specific to the Cheers binding.

**Verdict:** the data is never wrong; the state is always correctly rolled back to what it was
before the tap. The real defect is a silently-swallowed failure notification — the user's tap
appears to do nothing (a barely-perceptible flip-and-revert) with zero explanation why, rather
than the user being misled into believing a false success. Severity **High**, not "sev-1
data-integrity" — reclassified down from what the single screenshot alone would suggest, precisely
the kind of overstatement this section exists to avoid. Cheers is the feed's primary interaction,
so a user who taps it while offline gets no feedback whatsoever, which will read as "the button is
broken."

---

## FeedView / FeedPostCard

| State | File:line | What the screenshot shows | Severity |
|---|---|---|---|
| Empty | `FeedView.swift:72-78`; `/tmp/state-feed-empty.png` | Designed empty state: person-slash icon, "Nothing here yet", "Your feed shows posts from friends. Add a friend to start seeing their pints here." Centered, no dead spinner, no button (correctly — there's nothing to retry). | None — pass |
| Error (server) | `FeedView.swift:67-71`, `Components.swift:82-114`; `/tmp/state-feed-error-server.png` | "Couldn't load the feed" / "Something went wrong. Please try again." + working Retry button, `wifi.slash` icon. Positioned centered on screen, impossible to miss. Retry re-issues the load (still fails, since the fault stays active for the process, but the screen doesn't hang or blank — confirmed by `testFeedErrorServer`). | None — pass |
| Offline | `SupabaseError.swift:45`; `/tmp/state-feed-offline.png` | Same layout, message is `"You're offline. We'll try again when you're back."` — visibly distinct copy from the generic server error, correctly worded as "you" (network), not "we" (server). | None — pass |
| Rejected-not-outage (`rateLimited`) | `FeedView.swift:68`, `SupabaseError.swift:47`; `/tmp/state-feed-error-ratelimited.png` (before), `/tmp/state-feed-error-ratelimited-fixed.png` (after) | Message is honest: `"That's a lot at once — give it a moment."` — does not claim offline or claim a server outage. **Fixed:** the icon now varies by error kind (`FeedView.errorIcon(for:)`, `FeedView.swift`) — `hourglass` for `.rateLimited`, `wifi.slash` only for `.offline`, `lock` for auth/forbidden, `questionmark.circle` for not-found, `exclamationmark.triangle` for the rest — matching `DataExportView.errorMessage(for:)`'s standard of honest, correctly-attributed copy. Re-screenshotted with `-uiTestFailOperation feedPage.initial -uiTestFailError rateLimited`: hourglass icon next to the same honest text. Unit-tested in `FeedViewTests.swift` (`testRateLimitedIconDiffersFromOfflineIcon`, `testRateLimitedUsesAnHourglassNotAConnectivityIcon`). | Low — **Fixed**. |
| Failed `loadMore` mid-scroll | `FeedView.swift:128-148`; `/tmp/state-feed-loadmore-error.png` | A "Retry" pill appears in the list footer after scrolling past the (faulted) 21st post. Visually distinct from... | None — pass |
| `loadMore` reaches the natural end | `FeedView.swift:128-148` (no branch fires once `loadError == nil && !hasMore`); `/tmp/state-feed-loadmore-end.png` | ...simply nothing: the list ends after post #20, straight into the tab bar, no footer at all. This *is* distinguishable from the error case (Retry pill present vs. absent) — answers the specific question below — but there is no positive "you've reached the end" affirmation either; the absence of a footer is the only signal. | Low — distinguishable (the requirement), but a silent stop is a minor UX gap on its own. |
| Delete-post error | `FeedView.swift:114-121`; `/tmp/state-feed-delete-error.png` | `.alert("Couldn't delete that post", …)` **does** present (unlike Cheers below, before the fix), with "Something went wrong. Please try again." and an OK button. Confirmed dismissible: tapping OK clears it and the row's "Post options" menu is still usable immediately after — not stuck. | None — pass |
| Cheers-toggle error | `FeedViewModel.swift:264-285`, `FeedView.swift`; `/tmp/state-feed-cheers-error-silent-failure.png`, `/tmp/state-feed-cheers-error-rollback-uncheered.png` (before), `/tmp/state-feed-cheers-inline-error-fixed.png` (after) | See "The Cheers finding" above for the state-is-never-wrong evidence (unchanged). **Fixed** — see "Fixes applied" below for the real root cause, why the two-`.alert` hypothesis was wrong, and why the shipped remedy is inline text rather than a timed alert. Re-screenshotted with `-uiTestFailOperation toggleCheers -uiTestFailError offline`: "You're offline. We'll try again when you're back." renders as an inline banner above Barnaby's card, with the row staying usable underneath it. Regression test: `FeedUITests.testFeedCheersErrorShowsInlineMessage`. | **High — Fixed** |
| Photo tap target overflows the tile | `FeedPostCard.swift` (`photo`, `tile(for:)`); `/tmp/verify-portrait-card.png`, `/tmp/verify-loading-card.png`, `/tmp/verify-portrait-menu.png` | **Fixed — see "Fixes applied" §5.** The photo `Button`'s interactive region was the whole un-cropped `scaledToFill` image (338×451 for a portrait phone photo) rather than the 338×200 tile it draws, so 125pt of invisible photo overhung the header above and the Cheers/comments strip below; the post-options menu could not be tapped at all. `.clipShape` clips drawing, not hit testing. Fixed with a `Color`-sized tile + `.overlay` + `.contentShape`; the tap target is now exactly 200pt in every `RemoteImagePhase` and for every source aspect ratio. Regression test: `FeedUITests.testFeedPhotoTapTargetIsConfinedToTheTile`. | **High — Fixed** |
| Cheers-toggle spuriously opens Comments | `FeedPostCard.swift:200-224` (`footer`) | **Fixed — see "Fixes applied" §4.** Tapping `cheers-toggle` could flip that same post's `showingComments` to `true`, opening `PostCommentsSheet` on top of the feed. Root cause: `footer`'s `CheersButton` and comments `Button` shared one `HStack` in a `List` row with no `buttonStyle` set on either — the one place in this codebase that broke the `.buttonStyle(.plain)`-per-button convention `FriendsView.pendingRow` already uses for the identical shape. `.buttonStyle(.plain)` on each control fixes it. This also turned out to be the real root cause of the Cheers-alert finding above — see §4. Regression test: `FeedUITests.testFeedCheersToggleDoesNotOpenCommentsSheet`. | **High — Fixed** |

## ComposePostSheet

| State | File:line | What the screenshot shows | Severity |
|---|---|---|---|
| Empty | — | Not applicable: this is a write-only form (body + photo + place), not a list. There is no "nothing to show" state to design for. Judgment call, not a gap. | N/A |
| Error (server) | `ComposePostSheet.swift:82-99`; `/tmp/state-compose-error-server.png` | "Something went wrong. Please try again." rendered at the top of the `Form`, above the body field — impossible to miss, not below the fold. `Post` re-enabled immediately after (asserted by `testComposeErrorServer`), not stuck disabled. | None — pass |
| Offline | `SupabaseError.swift:45`; `/tmp/state-compose-offline.png` | `"You're offline. We'll try again when you're back."` — same honest, distinct copy as Feed's offline state. | None — pass |
| Photo-permission-denied | `ComposePostSheet.swift:172-177` (`PhotosPicker(selection:, matching: .images)`), `loadPhoto` at `ComposePostSheet.swift:230-241` | **Could not be driven, and reasoned to be structurally unreachable, not merely hard to script.** `grep -rn "PHPhotoLibrary\|requestAuthorization\|PHAuthorizationStatus"` across the whole app returns zero matches — nothing in this codebase ever asks for photo-library authorization. All three photo pickers in the app (`ComposePostSheet`, `EditProfileView`, `ProfileSetupFlowView`) use SwiftUI's `PhotosPicker` (`PhotosUI`), which is backed by the system `PHPickerViewController` running out-of-process; Apple's documented design for that picker requires **no** library authorization at all — it presents and lets the user pick regardless of the system Photos permission state, including a fully "Denied" one, because the host app never queries the library directly. `loadPhoto`'s only failure branch (`ComposePostSheet.swift:230-241`) is a transferable-load/decode failure ("Couldn't read that photo. Try another image."), not a permission error — there is no permission-error code path to reach. `NSPhotoLibraryUsageDescription` is declared in `Info.plist:47` but nothing in the code ever triggers the system prompt it would back. | Gap acknowledged, not a defect — the state genuinely does not exist in this app's current implementation. |

## PlacePickerSheet

| State | File:line | What the screenshot shows | Severity |
|---|---|---|---|
| Empty (no query yet) | `PlacePickerSheet.swift:41-94`; `/tmp/state-placepicker-empty.png` | Blank list under the search field — no placeholder text, no icon, no "type to search" hint. Not a designed empty state like Feed's/Comments' (no icon+title+message), just absence. Common enough for a search sheet (Contacts/Maps-style pickers often do this), but inconsistent with this app's own pattern elsewhere. | Low — trivial fix: an idle-state hint row. |
| No matches / offline — **fixed, now distinguishable** | `PlaceCompleter.swift` (`PlaceSearchStatus`, `resolvedStatus(resultsCount:failed:)`), `PlacePickerSheet.swift` (the `switch completer.status` row) | **Fixed.** `PlaceCompleter` now tracks `PlaceSearchStatus` (`.idle`/`.results`/`.noMatches`/`.failed`) instead of collapsing every empty outcome into a silent `results = []`: `completerDidUpdateResults` (a genuine zero-result success) sets `.noMatches`; `completer(_:didFailWithError:)` (the search itself couldn't run) sets `.failed`. `PlacePickerSheet` renders a distinct row for each: "No matches for "<query>"" (magnifying-glass icon) vs. "Couldn't search right now. Check your connection and try again." (`wifi.slash` icon) — neither one hides or disables the "Use "<typed text>"" fallback row, so posting is still never blocked (the redeeming property this finding always credited, preserved). A `#if DEBUG` seam (`DebugFaultInjector.Operation.placeSearch`, checked in `PlaceCompleter.query`'s `didSet` before it ever touches the real `MKLocalSearchCompleter`) makes both states reachable deterministically from a UI test, since `MKLocalSearchCompleter` talks to Apple's real servers and can't be fault-injected the way a Supabase repository call can. Re-screenshotted: `/tmp/state-placepicker-nomatches-fixed.png` (`-uiTestForceEmpty placeSearch`, typed "Zzqxnonexistentplaceqxyz123") and `/tmp/state-placepicker-failed-fixed.png` (`-uiTestFailOperation placeSearch -uiTestFailError offline`, typed "The Kings Arms" — the fallback button is visibly still present in both). Unit-tested in `PlacePickerTests.swift` (`testFailedSearchIsDistinctFromAGenuineZeroResultMatch`, `testSuccessfulSearchWithResultsReportsResults`, `testFailureTakesPriorityOverAStaleNonZeroResultsCount`). | **Medium — Fixed** |

*Not extended:* `PubsRepository.persist` (the other network call `resolve()` makes) is not one of
`DebugFaultInjector`'s 14 wired operations. It was deliberately not added: `resolve()` swallows
`persist`'s failures the same way (`PlacePickerSheet.swift:161`, another `try?`), so forcing it to
throw would reproduce the identical "silent fallback" screenshot already captured above, not a new
one — there is no error UI on this screen for a 15th operation to newly exercise.

## PostCommentsSheet

| State | File:line | What the screenshot shows | Severity |
|---|---|---|---|
| Empty | `PostCommentsSheet.swift:146-149`; `/tmp/state-comments-empty.png` | Designed empty state, matching Feed's pattern: bubble icon, "No comments yet", "Be the first to say something." | None — pass |
| Load error (server) | `PostCommentsSheet.swift:140-145`; `/tmp/state-comments-load-error.png` | "Couldn't load comments" / "Something went wrong. Please try again." + Retry, same `StatusView` pattern as Feed. | None — pass |
| Load offline | `SupabaseError.swift:45`; `/tmp/state-comments-load-offline.png` | `"You're offline. We'll try again when you're back."` — honest, distinct. | None — pass |
| Send error (server) | `PostCommentsSheet.swift:79-97`; `/tmp/state-comments-send-error.png` | "Something went wrong. Please try again." renders in full above the keyboard, not truncated — confirms `docs/ACCESSIBILITY_AUDIT.md`'s §6.3 fix (`.fixedSize(horizontal:false, vertical:true)`, applied after that pass found this exact text ellipsis-truncated at accessibility XXL) still holds at normal text size. Send re-enabled after failure (asserted). | None — pass |
| Send offline | `/tmp/state-comments-send-offline.png` | Same layout, `"You're offline. We'll try again when you're back."`, fully visible. | None — pass |
| Mentions with zero friends | `PostCommentsViewModel.swift:247-250` (`suggestions(for:)`, empty token matches all friends — none exist); `/tmp/state-comments-mentions-empty.png` | Typing `@` alone produces **no suggestion list at all** — not an error, not a "no friends to mention" message, just absence (the `if let token = activeToken, !suggestions.isEmpty` guard at `PostCommentsSheet.swift:99` means an empty result renders nothing). Reasonable (no error occurred), but indistinguishable from "mentions aren't a feature here" to a first-time user. | Low |
| Failed `loadMore` mid-scroll vs. reaching the end | `PostCommentsViewModel.swift:117-134`; `DemoWorld.swift` (Alice's post seeds exactly one comment) | **Could not be driven.** `loadMore()` only fires once the first page is full (`hasMore = page.count == pageSize`, pageSize 30); the demo seed's richest thread has one comment, so `hasMore` is always `false` and the paging path this app's own `.loadMore` operation exists to test is never reached by any UI interaction, regardless of fault injection. The seam (`postComments.loadMore`) is wired and unit-testable at the repository layer, but exercising it through the UI would require re-seeding `DemoWorld` with ≥30 comments on one post — a seed-data change, out of this audit's "don't fix/add app behavior" scope. Answered instead by the equivalent Feed case (23 seeded posts, page size 20), which **is** naturally reachable and shown above to be distinguishable. | Gap acknowledged — infrastructure exists, demo data doesn't exercise it for comments specifically. |

## ReportContentView

| State | File:line | What the screenshot shows | Severity |
|---|---|---|---|
| Empty | — | Not applicable — a report is a form (pre-selected reason + optional details), not a list. | N/A |
| Error (server) | `ReportContentView.swift:147-153`; `/tmp/state-report-error-server.png` | "Something went wrong. Please try again." at the top of the Form (matching `docs/ACCESSIBILITY_AUDIT.md` §6.3's fix, moved here from the bottom after that pass found the sibling "sent" confirmation unreachable-in-time at the bottom). Send re-enabled after failure (asserted). | None — pass |
| Offline | `SupabaseError.swift:45`; `/tmp/state-report-offline.png` | `"You're offline. We'll try again when you're back."` | None — pass |
| "Sent" confirmation (bonus, not one of the four required axes) | `ReportContentView.swift:137-146` | **Attempted, not independently re-confirmed.** A test tapping Send with no fault injected, waiting for the `report-content-sent` element, failed twice — once querying `staticTexts` (wrong: the confirmation is a `Label`, not a `Text`, unlike its four sibling inline messages, so that query was never going to match), once with a type-agnostic `descendants(matching: .any)` query (still didn't match within 10s). Rather than keep debugging what looks like a UI-test accessibility-tree quirk specific to `Label`, on a state that isn't one of this audit's four required axes, the test was dropped. `docs/ACCESSIBILITY_AUDIT.md` §6.3 already screenshotted this same confirmation successfully (at accessibility XXL, via its own scripted test) after moving it to the top of the Form, so there is independent prior evidence it renders — this pass just didn't reproduce that evidence itself. Stated plainly rather than papered over. | Not scored — out of scope; noted as an honest gap in *this* pass's evidence, not a suspected regression. |

## DataExportView

| State | File:line | What the screenshot shows | Severity |
|---|---|---|---|
| Empty | — | Not applicable — static explanatory text plus one action button; nothing list-shaped to be empty. | N/A |
| Error (server) | `DataExportView.swift:87-93`; `/tmp/state-dataexport-error-server.png` | "Something went wrong. Please try again." visible without scrolling, `Prepare my data export` re-enabled after failure (asserted). | None — pass |
| Offline | `SupabaseError.swift:45`; `/tmp/state-dataexport-offline.png` | `"You're offline. We'll try again when you're back."` | None — pass |
| Rejected-not-outage (`rateLimited`) | `DataExportView.swift:209-217` (`errorMessage(for:)`); `/tmp/state-dataexport-ratelimited.png` | **This is the good example.** `"You've used all 5 exports allowed today. You can try again tomorrow."` — specific, actionable, correctly attributes the cause to the client's own quota rather than an outage, and even tells the user when it resets. Deliberately overrides `SupabaseError.friendlyMessage`'s generic rate-limit copy for this one screen. This is what FeedView's rate-limit case (above) should read like. | None — pass, and the reference implementation for the Medium finding on Feed's icon. |

---

## The four specific questions

1. **Can an error message be dismissed, or does it persist forever?** Two different mechanisms,
   both fine, neither a bare dismiss-only-this-message control. The two `.alert`s (Feed's delete
   error, `FeedView.swift:114-121`) have an explicit OK button that clears the state and leaves the
   row usable — confirmed dismissible by `testFeedDeleteErrorAlert`. The five inline `Text`-based
   messages (compose, comments-send, report, data-export, and Feed/Comments' full-screen
   `StatusView` errors) have no standalone dismiss; they clear only when the next attempt starts
   (each `submit()`/`send()`/`export()` sets its error to `nil` on entry) or when the sheet is
   dismissed entirely (Cancel/Close). Not "stuck forever" — but there is no way to make an inline
   error go away without either retrying or leaving the screen.
2. **Does a failure leave a spinner running or a button permanently disabled?** No, in every case
   checked. `testComposeErrorServer`, `testCommentsSendErrorServer`, `testReportPostErrorServer`,
   and `testDataExportErrorServer` all assert their respective action button
   (`compose-post-submit`, `comment-send`, `report-content-send`, `data-export-prepare`) is
   `.isEnabled` again immediately after the failure — each `submit`/`send`/`export` function uses
   `defer { isX = false }` around its `do`/`catch`, so the in-flight flag always clears regardless
   of outcome.
3. **Is a failed `loadMore` distinguishable from reaching the end?** Yes, for Feed (the case this
   was actually testable for — see the PostCommentsSheet row above for why the comments equivalent
   couldn't be driven). `/tmp/state-feed-loadmore-error.png` shows a "Retry" pill in the footer;
   `/tmp/state-feed-loadmore-end.png` shows nothing at all past the last post — visibly different,
   confirmed side by side. The only softer finding: "the end" has no positive affirmation, just an
   absence, which is a minor, separate UX note, not a failure of distinguishability.
4. **Is the offline copy honest under `rateLimited`, where the server is up and the request was
   merely rejected?** Yes for the message text everywhere it was checked — `SupabaseError
   .friendlyMessage`'s `.rateLimited` case (`SupabaseError.swift:47`) never says "offline", and
   `DataExportView` overrides it with even more specific, correctly-attributed copy
   (`state-dataexport-ratelimited.png`). The one wrinkle: Feed's full-screen error state
   (`state-feed-error-ratelimited.png`) pairs that honest text with a `wifi.slash` icon shared
   verbatim with the genuine offline/server cases — the icon, not the words, implies a
   connectivity problem that isn't the actual cause. Logged as the Low finding above.

---

## Findings ranked by severity

| Rank | Severity | Finding | Where |
|---|---|---|---|
| 1 | **High — Fixed** | Cheers-toggle failure is completely silent — `cheersError` is set correctly but its `.alert` never presents; user gets a flip-and-revert with zero explanation. State itself is never wrong (see "The Cheers finding" above). **See "Fixes applied" §1/§4 below for the real root cause — it was not the two-`.alert` hypothesis, and the Menu/confirmationDialog-transition theory §1 originally landed on was also superseded by §4.** | `FeedView.swift:106-113` |
| 1b | **High — Fixed** | Tapping `cheers-toggle` could spuriously open that post's `PostCommentsSheet` (`showingComments` flips `true` on the wrong control). Same root cause as #1 — see "Fixes applied" §4. | `FeedPostCard.swift:200-224` |
| 1c | **High — Fixed** | The photo `Button`'s tap target was the un-cropped `scaledToFill` image rectangle, not the 200pt tile it draws (`.clipShape` clips drawing, not hit testing). 125pt of invisible tappable photo above and below the picture for a portrait phone photo; the post-options menu became un-tappable outright. Reported from a real device as "when i click on the picture it opens up the comments?". See "Fixes applied" §5. | `FeedPostCard.swift` (`photo`/`tile(for:)`) |
| 2 | **Medium — Fixed** | `PlacePickerSheet` cannot distinguish "offline" from "no matches" — both silently fall back to the same UI via `try?`, with no error/offline messaging at all on this screen. | `PlacePickerSheet.swift:127-167` |
| 3 | Low — Fixed | Feed's error `StatusView` uses the same `wifi.slash` icon for offline, server, *and* rate-limit — text is honest, icon overclaims "connectivity". | `FeedView.swift:68` |
| 4 | Low | `PlacePickerSheet`'s idle/empty state is a bare blank list, no hint text — inconsistent with the designed empty states elsewhere in the app. | `PlacePickerSheet.swift:41-94` |
| 5 | Low | Feed's "reached the end" state has no positive affirmation, only the absence of a footer. | `FeedView.swift:128-148` |
| 6 | Low | Mention autocomplete with zero friends renders nothing, not a "no friends yet" hint. | `PostCommentsSheet.swift:99` |
| — | Gap, not a defect | Composer photo-permission-denied is structurally unreachable — `PhotosPicker` requires no library authorization. | `ComposePostSheet.swift:172-177` |
| — | Gap, not a defect | Comments' `loadMore`-failure-vs-end distinction unverifiable via UI — demo seed data never fills a comment page. | `PostCommentsViewModel.swift:117-134` |
| — | Gap in this pass's evidence | Report "sent" confirmation not independently re-screenshotted this pass (test-query issue, not a suspected app regression); prior evidence stands in `docs/ACCESSIBILITY_AUDIT.md` §6.3. | `ReportContentView.swift:137-146` |

Everything else checked — Feed/Comments empty and error/offline states, Compose error/offline,
Report error/offline, DataExport error/offline/rate-limited, delete-error dismissibility, and
every button re-enable check — passed with no finding.

---

## Fixes applied (follow-up pass)

All three findings ranked above (Cheers alert, PlacePickerSheet offline-vs-no-matches, Feed's
rate-limit icon) are fixed. Each has a permanent regression test (kept, not throwaway) plus a
re-screenshot of the fixed state, read back as an image. The visual-verification UI test used to
gather those screenshots (`CheekyPintUITests/VerificationScreenshotTests.swift`) was, like
`StateAuditUITests.swift` before it, deleted after use and is not part of this commit.

### 1. Cheers alert — the real root cause, why the two-`.alert` hypothesis was wrong, and why the
   shipped fix is inline text, not a timed alert

The hypothesis going in was that two boolean-driven `.alert` modifiers chained on the same
`Group` (one for `cheersError`, one for `deleteError`) conflict, and that only one can ever
present. That was the natural first suspect, and the first thing tried: collapsing both into a
single `.alert(_:isPresented:presenting:actions:message:)` keyed on a two-case enum. **It fixed
nothing.** With only one `.alert` left in the tree, `cheersError`'s failure still never presented
while `deleteError`'s still did — proving the *count* of `.alert` modifiers was never the
variable, contrary to the hypothesis.

The actual mechanism was isolated by elimination, each variable ruled out individually while
holding the rest constant, all verified with the same UI test (now
`FeedUITests.testFeedCheersErrorShowsInlineMessage`, forcing `toggleCheers` to fail via
`-uiTestFailOperation toggleCheers -uiTestFailError offline` and tapping Barnaby's — the
*uncheered* — post's Cheers button):

- Not the number of `.alert`s (one, same result as two — above).
- Not *where* the alert is attached — tried the enclosing `Group`, the `List` directly, and
  attached per-row inside the `ForEach`. Same silent non-presentation every time.
- Not `CheersButton`'s `.animation(value: cheered)` spring effect — removed it entirely, same
  result.
- Not the simultaneous `posts` array mutation (the optimistic-flip-then-rollback) — removed that
  too (leaving `cheersError` as the only thing `toggleCheers`'s failure path touched), same
  result.
- Not raw elapsed wall-clock time before checking — `Task.yield()` and `Task.sleep` up to 300ms
  before setting `cheersError`, same result.

The one thing that reliably flipped it: **whether the tap that leads to the failure passes
through a native `Menu`/`confirmationDialog` transition first.** `FeedPostCard`'s delete flow
does (tap "Post options" → `Menu` → `confirmationDialog` → confirm); `CheersButton` is a plain,
un-menued `Button`. This was proven by swapping the wiring, not just observed as a correlation:
temporarily making `cheers-toggle` call `onDeletePost` (routing the *already-working* delete
alert through a plain-button path) reproduced the silent failure; temporarily making the delete
menu item skip its `confirmationDialog` (while staying inside the `Menu`) did not break it. A
real `DispatchQueue.main.asyncAfter` delay of ~0.5s before the alert-driving state change also
reproduced the effect `Menu`/`confirmationDialog` provide for free (0.25s was measured as not
enough, 0.5s was, consistently) — real evidence about *what kind* of bug this is (a SwiftUI/UIKit
presentation-transaction race specific to a modal triggered by a plain `Button`'s directly
invoked, detached `Task`), not a defect in `toggleCheers` itself (its rollback logic was already
correct — see "The Cheers finding, precisely" above, unchanged).

**Correction (tap-routing pass, see §4 below): this Menu/confirmationDialog conclusion was a real,
reproducible correlation, but not the actual mechanism.** The elimination list above never tested
button style, because at the time nothing pointed at `FeedPostCard.footer`'s `CheersButton`/
comments-`Button` pair as a suspect beyond being the tap targets themselves. §4 found that pair
shares one `HStack` in a `List` row with no `buttonStyle` set on either, which lets a
`cheers-toggle` tap get misrouted to the sibling comments `Button` and spuriously present
`PostCommentsSheet` — and a sheet already mid-presentation is what actually blocked the alert
(a second modal can't present over one already up). The delete flow's `Menu`/`confirmationDialog`
never triggered that mis-route, which is why swapping the wiring correlated so cleanly with
Menu/confirmationDialog presence — the correlation was real, the causal story attached to it
wasn't. Fixing the button style alone (§4), with no change to presentation plumbing, was verified
to make a reintroduced live-read `.alert` for `cheersError` present reliably. The wall-clock-delay
evidence below is unaffected by this correction — a real delay genuinely did reproduce the same
symptom, because it's *also* enough time for a human or a UI test to observe the sheet having
opened and closed, or for another render pass to paper over the mis-route; it was never a safe
signal of the actual mechanism, just a confound that happened to move in the same direction.

**That delay was rejected as the shipped fix.** It is tuned to one machine on one day; it delays
the user's own feedback for no reason they would understand; and a slower device, a cold launch,
or a loaded CI runner can blow past a wall-clock guess that a fast one happens to clear today. A
timing constant is what you reach for when you can't express the actual condition — exactly the
case where it hides the problem instead of solving it.

**The shipped fix removes the failure mode instead of timing around it: `cheersError` is no
longer presented via `.alert` at all.** It is plain inline content in `FeedView`
(`Text(cheersError)`, `accessibilityIdentifier("feed-cheers-error")`, pinned above the list via
`.safeAreaInset(edge: .top)`), matching how every other transient error in this app is already
reported (`ComposePostSheet`, `PostCommentsSheet`, `ReportContentView`, `DataExportView`). Inline
content has no separate presentation step to race against — it is part of the same view-body
evaluation that already, provably, reads `model.cheersError` correctly on every render — so
nothing about *this* finding is timing-dependent any more: no `sleep`, no `Task.sleep`, no
deferral, in the app or in the regression test. `deleteError` keeps its `.alert`, unchanged — its
own `Menu`/`confirmationDialog` already gives it the transaction gap the modal needs, so it never
needed fixing. `FeedViewModel.toggleCheers` now clears `cheersError` on entry, matching the
clear-on-retry convention the other four inline-error screens already use (there's no dismiss
button any more), and `AccessibilityAnnouncer` (the same type those four screens use) announces it
for VoiceOver — presenting via `.alert` used to give that for free, and moving to inline text must
not lose it.

Verified: `FeedUITests.testFeedCheersErrorShowsInlineMessage` fails against a version of
`FeedView` with the inline banner removed entirely (surfacing nothing, simulating the original
silent failure) with
`XCTAssertTrue failed - a failed Cheers toggle must surface an inline message naming the failure,
not a silent flip-and-revert`, and passes against the fix, consistently across repeated runs, with
no sleep anywhere in the assertion path. Re-screenshotted:
`/tmp/state-feed-cheers-inline-error-fixed.png` — "You're offline. We'll try again when you're
back." renders as a red inline banner at the top of the feed, above Barnaby's card (correctly
rolled back to "0 Cheers"); the row stays usable underneath it.

**A separate, pre-existing defect surfaced while diagnosing this — not one of this pass's three
findings, and not introduced by the fix above.** While screenshotting, `cheers-toggle`'s tap was
observed to sometimes *also* flip that same post's `showingComments` to `true`, spuriously opening
`PostCommentsSheet` on top of the feed. This is not a screenshot artifact — confirmed via a full
`app.debugDescription` accessibility-tree dump showing the Comments `NavigationBar` and its
`Close` button genuinely present at the same moment `feed-cheers-error` is. Root-caused as
pre-existing, not caused by moving Cheers to inline text: reproduced identically against the
original, currently-shipped `.alert`-based code, checked immediately after the tap (before its
0.5s delay elapses) — the glitch fires there too. The old code's alert only ever *looked* clean
because presenting a new modal ~0.5s later happens to force-dismiss the wrongly-opened sheet;
confirmed the glitch does **not** self-correct on its own by waiting 6 real seconds with no alert
in the picture at all. It reproduces with a plain `Button` calling a `Task` that fails
synchronously fast (the same class of trigger as finding 1 itself), independent of the List's
`.safeAreaInset`/wrapping structure, explicit row `.id`, or timing (0s/0.1s/0.5s delays before
showing the banner all still show it) — ruling out everything this pass could test without
starting a second, open-ended investigation.

**Status: fixed in the tap-routing pass — see §4 below.** It predated this change and was not
introduced by moving Cheers to inline text, but it turned out not to be a separate, lesser
curiosity either: it was the actual root cause of the Cheers-alert finding above, discovered by
finally testing the one variable the elimination list never tried, button style. See §4 for the
fix, the reliable (non-probabilistic) reproduction recipe, the regression test, and the controlled
experiment that re-attributes the alert's original failure to this same cause.

### 2. `PlacePickerSheet` — offline vs. no-matches

`PlaceCompleter` gained a `PlaceSearchStatus` (`.idle`/`.results`/`.noMatches`/`.failed`) computed
by a pure, unit-tested `resolvedStatus(resultsCount:failed:)`. `completerDidUpdateResults` (the
completer ran and returned some — possibly zero — results) maps to `.noMatches`/`.results`;
`completer(_:didFailWithError:)` (the completer's request itself failed) maps to `.failed`.
`PlacePickerSheet` renders a distinct row for each, both leaving the always-present "Use
"<typed text>"" fallback button untouched — typed free text remains usable and posting is never
blocked, regardless of which state fired.

Because `MKLocalSearchCompleter` talks to Apple's own servers (not a Supabase repository call),
it can't be fault-injected via `DebugFaultInjector.throwIfFaulted` the way every other operation
in this app can. A new operation, `DebugFaultInjector.Operation.placeSearch`, and a new
non-throwing query, `DebugFaultInjector.isFaulted(_:)`, let `PlaceCompleter.query`'s `didSet`
short-circuit deterministically in `#if DEBUG` builds — `-uiTestForceEmpty placeSearch` forces
`.noMatches`, `-uiTestFailOperation placeSearch -uiTestFailError <kind>` forces `.failed` —
without ever touching the real completer or depending on the test environment's actual network
reachability.

Verified: `PlacePickerTests.testFailedSearchIsDistinctFromAGenuineZeroResultMatch` fails against
the pre-fix collapse (confirmed by reverting `resolvedStatus` to always return `.noMatches`
regardless of `failed`) with `XCTAssertNotEqual failed: ("noMatches") is equal to ("noMatches") -
a search that could not run must not look identical to one that ran and found nothing`, and
passes against the fix. Re-screenshotted: `/tmp/state-placepicker-nomatches-fixed.png` (typed
"Zzqxnonexistentplaceqxyz123" with `-uiTestForceEmpty placeSearch`) shows "No matches for
"Zzqxnonexistentplaceqxyz123""; `/tmp/state-placepicker-failed-fixed.png` (typed "The Kings Arms"
with `-uiTestFailOperation placeSearch -uiTestFailError offline`) shows "Couldn't search right
now. Check your connection and try again." — both screenshots show the "Use "…"" fallback row
still present and tappable.

### 3. Feed's rate-limit icon

`FeedView.errorIcon(for:)`, a pure `static func` (unit tested directly, no view or container
needed), replaces the hard-coded `"wifi.slash"` `StatusView` icon: `.offline` → `wifi.slash`,
`.rateLimited` → `hourglass` (the audit's own suggested fix, verbatim), `.notAuthenticated`/
`.forbidden` → `lock`, `.notFound` → `questionmark.circle`, everything else →
`exclamationmark.triangle`. Matches `DataExportView.errorMessage(for:)`'s standard for honest,
correctly-attributed copy, now extended to the icon.

Verified: `FeedViewTests.testRateLimitedIconDiffersFromOfflineIcon` fails against the pre-fix
hard-coded icon (confirmed by reverting `errorIcon(for:)` to unconditionally return `"wifi.slash"`)
with `XCTAssertNotEqual failed: ("wifi.slash") is equal to ("wifi.slash") - a client-side throttle
must not show the same icon as a genuine outage`, and passes against the fix. Re-screenshotted:
`/tmp/state-feed-error-ratelimited-fixed.png` (`-uiTestFailOperation feedPage.initial
-uiTestFailError rateLimited`) shows the hourglass icon next to "Couldn't load the feed" / "That's
a lot at once — give it a moment."

### 4. Cheers-toggle spuriously opens Comments — the real root cause, and a correction to §1

**Hypothesis going in:** `FeedView` renders `List { ForEach(model.posts) { FeedPostCard(...) } }`
(`FeedView.swift:147-148`), and `FeedPostCard.footer` (`FeedPostCard.swift:200-220`) puts two
plain `Button`s — `CheersButton` and the comments button — in one `HStack`, with **no
`buttonStyle` set anywhere on the card** (the only `buttonStyle` in the file was the unrelated
`.bordered` on the paging-footer Retry button, `FeedView.swift:262`). Multiple plain `Button`s in
one `List` row with no explicit style is a known SwiftUI hit-testing trap. Confirmed, not assumed:
`FriendsView.pendingRow` (`FriendsView.swift:97-113`) has the identical shape — two plain `Button`s
in one `HStack` in a `List` row — and already applies `.buttonStyle(.plain)` to each one
individually; `FeedPostCard.footer` was the one place in this codebase that broke that established
convention.

**Fix:** `.buttonStyle(.plain)` on `CheersButton` and on the comments `Button` in
`FeedPostCard.footer`. No visual change (`.plain` removes chrome that was never there), no timing
element — each control becomes its own independently hit-tested target regardless of how fast or
slow its action runs.

**Verified as the actual cause, not a coincidental fix, three ways:**
- **RED:** `FeedUITests.testFeedCheersToggleDoesNotOpenCommentsSheet` (added first, against
  unmodified `HEAD`) fails with `XCTAssertFalse failed - tapping Cheers must not spuriously open
  that post's comments sheet`, reproduced immediately on the very first tap — no wait, no retry,
  matching the pre-existing finding's own observation that this doesn't self-correct.
- **GREEN:** the same test passes once `.buttonStyle(.plain)` is added, with nothing else changed.
- **Root-cause correction for §1, not just a second bug fixed by coincidence:** with the button-
  style fix applied but *no other change*, the original pre-fix presentation of `cheersError` — a
  live-read `.alert(isPresented: Binding(get: { model.cheersError != nil }, ...))`, temporarily
  reintroduced purely as an experiment and removed again afterward — presented reliably across
  three repeated runs (`app.alerts["Couldn't update Cheers"].waitForExistence(timeout: 10)`
  succeeded every time). With the button-style fix reverted (same live-read `.alert`, `git stash`
  used to isolate the one variable), the identical experiment failed identically to §1's original
  finding, also across the runs checked. This is the causal proof, not a correlation: the Cheers
  alert's non-presentation and the spurious-Comments-open defect were the **same bug** — the
  mis-routed tap was intermittently firing the comments button's action (`showingComments = true`)
  as well as (or instead of) `onToggleCheers`, and a sheet already presenting is what silently
  blocked the alert from presenting over it. `FeedPostCard`'s delete flow never triggered this
  because `Menu`/`confirmationDialog` aren't affected by `footer`'s missing button style at all —
  the correlation §1 found was real, but attached to the wrong mechanism.

**The shipped fix keeps the inline banner from §1, unchanged.** Inline content remains the better
affordance for a failed Cheers tap regardless of whether the alert *can* now present — this
section only corrects the historical record of *why* the alert used to fail, it does not revert
§1's remedy. `cheersError` is still `Text`, still `accessibilityIdentifier("feed-cheers-error")`,
still in the `safeAreaInset`; no app code from §1 changed.

**Regression check (verified, not assumed, then reverted — none of this is in the shipped diff):**
`FeedPostCard` sits in a row with a `Menu` (`postMenu`) and a `confirmationDialog`, and
`PostCommentsSheet` has swipe-to-delete on comment rows — all three named as at-risk by this pass.
A throwaway UI test (deleted after use, this project's established convention — see "regression
suite or throwaway" below) drove, on top of the fix: a genuine tap on the comments button (sheet
still opens correctly); adding and swipe-deleting a comment (swipe action still reveals Delete,
deletion still removes the row); and the post-options `Menu` → "Delete this post" →
`confirmationDialog` → confirm flow end-to-end (dialog still shows "Delete this post?"/"This can't
be undone.", confirming still removes the post). A second throwaway test repeated the Cheers-tap
and comments-tap checks at accessibility XXL Dynamic Type (`-UIPreferredContentSizeCategoryName
UICTContentSizeCategoryAccessibilityXXL`, matching `docs/ACCESSIBILITY_AUDIT.md`'s own method) —
both controls stayed tappable and correctly wired, and the spurious-open defect did not reappear at
that size either. All of these passed; none is part of this commit.

### 5. The photo's tap target was the whole un-cropped image, not the tile it draws

**Reported from a real device, running Staging against hosted Supabase:** *"when i click on the
picture it opens up the comments?"* Base HEAD `261a223`.

**What was actually wrong, and how it was proved.** `FeedPostCard.photo` built its `Button` label
as `RemoteImage { ZStack { Color; image.resizable().scaledToFill() } }.frame(maxWidth: .infinity,
minHeight: 200, maxHeight: 200).clipShape(RoundedRectangle(...))`. `scaledToFill` returns a size
*larger* than the one it is proposed — that is the whole meaning of "fill" — so the `ZStack`
reported the entire un-cropped image rectangle as its size. The `.frame` above it still reported
200pt to the enclosing `VStack` (so the card laid out correctly), and `.clipShape` clipped the
*drawing* to 200pt (so the picture looked right) — but **neither one clips hit testing or the
accessibility frame**. The `Button`'s interactive region was the full image rectangle, centred on a
200pt picture.

Measured directly, by reading `XCUIElement.frame` for `feed-post-photo-*` rather than inferring it:

| Photo | Element frame | Drawn tile | Overhang, each direction |
|---|---|---|---|
| Demo seed, landscape 1200×900 | 338 × **253** | 338 × 200 | 27pt |
| Portrait 3:4 (a phone photo) | 338 × **451** | 338 × 200 | **125pt** |
| Still loading (`.loading` phase) | 338 × 200 | 338 × 200 | 0 |

That overhang is invisible and tappable. It covers `header` above (the photo is a later sibling in
the `VStack`, so it wins every hit test in that overlap) and `bodyText`/`footer` below. The
concrete, reproducible consequence: with a portrait photo the post-options menu is **not tappable
at all** — XCUITest refuses the tap outright, `Failed to not hittable: Button, {{326.0, 376.0},
{44.0, 44.0}}, identifier: 'post-menu-…'`, because the photo answers the hit test at the menu's own
centre point. The dead space in the Cheers/comments strip goes the same way. Cheers and the
comments button themselves keep working (later siblings still win over the photo), and `List` cells
clip the overhang at the row boundary, so it never reaches a neighbouring post — both verified by
coordinate-tap probes, not assumed.

**Why the aspect ratio is the whole story, and why it is not an exotic case.** `ImageResizer.jpeg`
(`ComposePostSheet.swift:234`, `maxDimension: 1600`) preserves the source aspect ratio, so a post
photo is whatever shape the camera produced — portrait, overwhelmingly. `261a223`'s own commit
message names this: the feature exists because "a portrait photo showed only a narrow cropped
band". The seeded demo photo, `demo-pint.png`, is the one shape that hides the defect.

**Why the UI test that shipped with the feature passed while this was live.**
`testFeedPhotoTapOpensViewerWithoutMisroutingOtherControls` is not a bad test; it is a test of the
other direction, run against the one input that cannot fail it.
- It asserts only that *tapping the photo fires nothing else*. It never asserts the converse — that
  the photo's tap target is confined to the photo, and that the row's other controls are still
  reachable. A control that has been swallowed whole is invisible to "did tapping X fire Y".
- It runs in demo mode against the bundled **landscape** `demo-pint.png`, whose overhang is 27pt
  and reaches nothing. The user hit this in Staging, where the photo is a real (portrait) phone
  photo fetched over the network. Aspect ratio, not the network, is the variable — the `.loading`
  phase was suspected first and cleared: a `RemoteImage` held in `.loading` reports a 338×200
  frame, exactly the tile, because a `ProgressView` cannot inflate a `ZStack` the way
  `scaledToFill` can.
- It taps `photo.tap()`, i.e. the centre of the element's frame — which, for a centred overhang,
  is still the centre of the drawn picture. The one point XCUITest picks is the one point that
  behaves.

**Verdict: salvageable, and kept.** It guards a real property (the photo tap must not fire Cheers,
Comments or the menu) that nothing else covers, and that property did not regress. It is
*insufficient*, not wrong, so it is complemented rather than replaced — by
`testFeedPhotoTapTargetIsConfinedToTheTile`, which asserts the missing direction, against the
missing input.

**Fix, structural rather than a tuned number.** A `Color` carries the tile's size; the image moves
into an **`.overlay`** (an overlay is proposed its parent's size and can never inflate it, unlike a
`ZStack` child); `.contentShape` pins the interactive region to exactly the shape `.clipShape`
draws. The label's layout size is now `photoHeight` in every `RemoteImagePhase` and for every
source aspect ratio, so the tap target cannot drift from the picture again. No appearance change:
same `scaledToFill` crop, same rounded corners — confirmed by screenshot, below.

**Hoisted with it: all of the card's presentations, to the row's root, driven by one enum.**
`FeedPostCard` attached `.sheet(isPresented: $showingReport)` to the header, `.fullScreenCover
(isPresented: $showingPhotoViewer)` to the photo, and `.sheet(isPresented: $showingComments)` to
the footer — three presentation modifiers on three sibling subviews of one recycled `List` row.
They are now one `CardPresentation?` on the card's root (`.sheet(item:)` for comments/report,
`.fullScreenCover(item:)` for the photo, `.confirmationDialog` alongside them), the same remedy
`FeedView` already applies to its own alerts via `FeedAlert`. `item:` rather than `isPresented:`
means the presented content is derived from the same value that decided to present it, and one
enum makes "the comments sheet and the photo viewer are both open" unrepresentable rather than
merely unlikely — which is the exact shape of the reported symptom. **Stated plainly: this part is
hardening, not a proven fix.** No experiment in this pass produced a wrong *presentation*; every
mis-routing observed was hit-testing, and the tap-target fix is the one with a red-to-green proof
behind it. The hoist is kept because the shape it removes is a documented hazard, this row has now
produced three defects, and the existing suite (Report sheet, Comments sheet, photo viewer, delete
`confirmationDialog`) re-verifies every path it touches.

**Verified:**
- **RED:** `FeedUITests.testFeedPhotoTapTargetIsConfinedToTheTile`, run against `261a223`'s
  `FeedPostCard.swift` restored verbatim over the rest of this pass's tree, fails with
  `XCTAssertFalse failed - the photo's tap target must not overlap the post-options menu (loaded)`.
- **GREEN:** it passes against the fix, in both the loaded and the still-loading phase, with the
  photo's frame measured at exactly `(32.0, 432.0, 338.0, 200.0)` in both — the tile, and only the
  tile.
- **Screenshots, read back as images, in the portrait/network-loaded shape the defect needs, not
  the demo-bundled landscape one:** `/tmp/verify-portrait-card.png` — Barnaby's portrait photo
  cropped to the same 200pt rounded tile as before, body text and Cheers/comments row unchanged;
  `/tmp/verify-loading-card.png` (`-uiTestStallOperation imageLoad`) — the same 200pt tile with a
  spinner, identical footprint, which is what makes the phase irrelevant to the tap target;
  `/tmp/verify-portrait-menu.png` — the post-options menu open on that same portrait card, showing
  "Report", the control that could not be tapped at all before this fix.
- **No timing element anywhere:** no `sleep`, `Task.sleep`, `asyncAfter` or tuned threshold in the
  app or the test. Every assertion reads geometry or hittability that is already settled.

**What could not be verified, stated rather than papered over.** The literal reported symptom —
tapping the picture opening the *comments sheet* — was never reproduced in the simulator, across:
`.loading` vs `.success` phase; landscape vs portrait vs caption-less posts; adjacent photo posts;
scroll/recycle, pull-to-refresh, `loadMore`, tab-away-and-back; opening the compose sheet, the
Report sheet, the comments sheet or Cheers immediately beforehand; a 3×3 grid of coordinate taps
across the drawn tile; accessibility XXL; slight-drag and double taps. What *was* reproduced is a
deterministic wrong-control tap-routing defect in exactly that `Button`, of exactly the family this
row has now produced twice before. Two gaps remain: the app could not be pointed at the real
private bucket (no credentials available to this pass — the network-in-flight state is stood in for
by `DebugFaultInjector`'s new `imageLoad` stall seam, and the real photo *shape* by
`-uiTestPortraitPhoto`), and only the iOS 26.5 simulator runtime is installed, so an iOS-version-
specific presentation difference on the reporter's own phone could not be excluded.

**New permanent infrastructure (small, `#if DEBUG`, matching the `placeSearch` precedent):**
`DebugFaultInjector.isStalled(_:)` + `-uiTestStallOperation` + `Operation.imageLoad` — a third
outcome alongside "fails" and "succeeds with nothing", because a request still in flight is a
genuinely different UI state; it is a plain early return with no clock involved.
`DemoWorld.demoPhotoFilename` + `-uiTestPortraitPhoto` + `Resources/DemoAssets/demo-pint-portrait.png`
— the seed's photo could only ever be landscape, which is precisely why this shipped.

### Final test counts

As of the photo tap-target pass (base HEAD `261a223`): 147 `CheekyPintTests` (unchanged — this pass
added no unit tests; the defect is geometry the simulator has to measure, which no unit test can
see), 9 `CheekyPintUITests` (8 baseline + 1:
`FeedUITests.testFeedPhotoTapTargetIsConfinedToTheTile`), `CheekyPintCore` 77 and `corecheck` 65
re-run and passing. The SQL suite (114) was untouched — nothing under `supabase/` changed — and was
not re-run. Two throwaway UI test files (`PhotoTapReproTests.swift`, the reproduction sweep, and
`VerificationScreenshotTests.swift`, the screenshot pass) were deleted after use, matching this
project's established convention below.

As of the tap-routing pass (base HEAD `b7f4e85`): 147 `CheekyPintTests` (unchanged — this pass
added no unit tests, only a UI test and a one-line-per-button view change), 7 `CheekyPintUITests`
(6 baseline + 1: `FeedUITests.testFeedCheersToggleDoesNotOpenCommentsSheet`), all passing.
`CheekyPintCore` (77) and `corecheck` (65) re-run and still passing — untouched by this pass, run
anyway since the button-style fix lives in the app target. The SQL suite (114) was untouched (no
file under `supabase/` changed) and not re-run this pass. Two throwaway UI tests
(`testTEMPMenuDeleteConfirmationAndSwipeStillWork`, `testTEMPButtonsRemainUsableAtAccessibilityXXL`)
verified no regression to the Menu/confirmationDialog/swipe/Dynamic-Type surfaces this fix could
plausibly have touched, then were deleted — not part of this commit, matching this project's
established throwaway-audit-test convention.

Earlier in this document (the original audit pass, base HEAD `7c3f220`): 147 `CheekyPintTests`
(140 baseline + 7: 4 in `FeedViewTests.swift`, 3 in `PlacePickerTests.swift`), 6 `CheekyPintUITests`
(5 baseline + 1: `FeedUITests.testFeedCheersErrorShowsInlineMessage`), all passing. `CheekyPintCore`
(77), `corecheck` (65), and the SQL suite (114) were untouched by that pass.

---

## `StateAuditUITests.swift`: regression suite or throwaway?

**Removed.** Kept only long enough to gather the evidence cited above; not committed.

Reasons:
- The file's own doc comment (written by the pass that started it) already called it "THROWAWAY
  ... deleted after the audit pass, same method the accessibility audit used" — and that
  precedent is real: `docs/ACCESSIBILITY_AUDIT.md`'s "Method" section describes the identical
  pattern (a scripted UI test that gathers screenshot evidence, then is deleted, with the findings
  living in the markdown doc instead). Diverging from an established, working convention needs a
  reason; there wasn't a strong one.
- Several of its tests use `sleep(1)`/`sleep(2)` rather than proper wait predicates — fine for a
  one-off evidence-gathering pass run by a human/agent reviewing screenshots afterward, but the
  wrong shape for a suite meant to run unattended in CI indefinitely (flaky-by-construction timing
  assumptions, e.g. exactly how long a fault injected round-trip takes in demo mode).
- Two genuinely new things it found — the Cheers silent-alert defect and the `PlacePickerSheet`
  offline/no-matches conflation — are captured here, in this document, as findings with file:line
  and severity. That is the durable artifact; a 300+ line UI test file asserting the *current*,
  partially-broken behavior (e.g. "the Cheers alert doesn't show" has no assertion precisely
  because asserting broken behavior is not what a regression suite should do) would either need to
  assert nothing (as it does today) or assert the bug, neither of which is a good permanent test.
- When the Cheers alert and `PlacePickerSheet` findings are actually fixed, the right move is to
  write **new**, properly-asserting regression tests against the fixed behavior at that time — not
  to inherit this pass's evidence-gathering harness wholesale.

**Kept, either way, as permanent infrastructure:** `CheekyPint/Core/Utilities/DebugFaultInjector.swift`
and `CheekyPintTests/DebugFaultInjectorTests.swift`. The seam has value independent of this one
audit — any future screen or regression test that needs a deterministic failure/empty state can
use it for free, and its own unit tests (parsing/mapping logic) are cheap, fast, and not
sleep-based.

---

## Summary of what was already done vs. added in this pass

**Already done (uncommitted, by the interrupted pass; verified, not redone):** the fault-injection
seam and its 12 unit tests; all 14 repository operations wired in `FeedRepository`/
`FriendsRepository`; roughly 19 of the `StateAuditUITests` methods covering most of the
empty/error/offline matrix above.

**Added in this pass:** `testFeedErrorRateLimited` (Feed's rate-limit icon/copy finding);
strengthened `testFeedDeleteErrorAlert` to assert OK actually dismisses and the row stays usable;
`testFeedCheersErrorRollsBackOnAnUncheeredPost` (the hard proof behind the Cheers finding); this
document; and the decision to remove the whole UI test file after use.
