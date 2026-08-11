# Social feed + instant beer logging — design

Date: 2026-08-11
Status: approved. Part A + Part C implemented (branch `feat/instant-log-nudge`). Part B1 (backend) in progress on `feat/feed-backend`; Part B2 (client) not started.

## Context

Two changes, specced together because the first one frees the image infrastructure the second one
needs.

The pint-logging catalog currently renders 98 beer cards backed by hot-linked Wikimedia Commons
photos. A licence audit found **12 of the 15 distinct photos require visible attribution**
(CC BY-SA 2.5/3.0/4.0, CC BY 2.0) and none is displayed, so shipping is a licence violation.
Several are also photos of live commercial brands (Puntigamer, Stiegl, Ottakringer, Chimay,
Erdinger), which is trademark exposure independent of copyright, and hot-linking Wikimedia from a
shipping app is against their robot policy at any volume.

Removing the photos resolves all three problems at once and makes logging a single tap.

The feed is the app's last planned feature: a friends-only place to post a photo or a status, get
Cheers, comment, and tag where you are.

The name **Cheers** is already taken twice, so the feed reaction forces a rename (Part C).

## Goals

- Logging a beer takes one tap and shows the existing `+1 succulence` celebration.
- No third-party image licensing or trademark exposure anywhere in the app.
- A friends-only feed with posts, Cheers, comments, `@` mentions and location tags.
- Moderation tooling that actually covers posts and comments, so the 17+ submission story holds.

## Non-goals (deliberately excluded)

- Push notifications (needs APNs + the paid programme; separate project)
- A public or global feed — friends-only, decided explicitly
- Post editing, nested comment replies, video, Cheers on comments
- Restoring camera or device-location permissions
- Reviving pub sessions / clinks, which remain unreachable legacy

## Part A — instant beer logging

### Behaviour

The horizontal card grid becomes a **compact searchable list of beer rows**: name, plus country and
style as secondary text. No imagery. Tapping a row logs that beer immediately with defaults
(default serving, alcoholic, `occurredAt = now`, no note) and presents `PintPourView`
(`+1 succulence`).

The other fields are **not removed** — they move into a collapsed `Details` disclosure inside the
sheet: serving type, custom volume, the alcohol-free toggle, time, and the private note. Whatever
is set there applies to the next tap. This keeps the alcohol-free distinction, which
`WelfareMonitor` depends on to count *alcoholic* entries when deciding whether to show the welfare
notice instead of a celebration — `RESPONSIBLE_DRINKING.md` treats that as a hard requirement.

`PourToLogButton` and the `fillToLogSection` are removed, since the tap is now the logging action.

**Duplicate protection.** Today one `idempotencyKey` is generated per sheet presentation, which was
sufficient when logging happened once per sheet. With tap-to-log the sheet can log repeatedly, so
the key is scoped **to the beer, not to the tap**: a pending `(beerID, key)` pair is held, reused
when the same beer is tapped again, replaced when a different beer is tapped, and cleared on
success. Taps are ignored while `isSaving` is true.

Keying per *tap* would be wrong: `createPint` dedupes on the key (master prompt §7.8), so if a
request succeeds server-side but its response is dropped, the user sees an error, taps the same beer
again, and a fresh key creates a **second entry** — inflating the very count `WelfareMonitor` uses
to decide when to show the welfare notice. Keying per beer keeps a genuine retry deduped while
letting a different beer log independently.

Accidental taps are further covered by the existing undo banner (`undo_recent_pint_entry`, Home,
grace period).

This trades §7's "nothing is stored until the user confirms" for "the tap *is* the confirmation,
and undo is one tap away" — an accepted, deliberate change.

### Removals

- `BeerChoice.imageURL`, `BeerChoice.sourceURL`, `commonsImageURL`, `commonsSourceURL`,
  `onlineImageFile`, `fallbackImageFile`, `thumbnailWidth`, `thumbnailPathAllowed`
- `GeneratedBeerArtwork` and the `beerImage` / `fallbackImage` views
- `CheekyPintTests/BeerImageURLTests.swift` (the URLs it pins cease to exist)
- The `CryptoKit` import in `LogPintSheet.swift`

### Retained and repurposed

`ImageLoader` and `RemoteImage` stay — the feed uses them for post photos. `RemoteAvatar` is
untouched.

The beer catalog itself (98 entries: id, name, country, style, nickname, glassNote, roast) is
unchanged. Only imagery goes.

## Part B — the feed

### Data model

Four tables, following existing conventions: RLS enabled, `revoke all` from
`public, anon, authenticated`, all access through `security definer` RPCs with `set search_path = ''`.

**`posts`**

| column | type | notes |
|---|---|---|
| `id` | uuid pk | `gen_random_uuid()` |
| `author_id` | uuid not null | → `profiles(id)` on delete cascade |
| `body` | text null | `char_length <= 500` when present |
| `image_path` | text null | storage key in `post-images` |
| `place_label` | text null | `char_length <= 80`; display string |
| `pub_id` | uuid null | → `pubs(id)` on delete set null |
| `created_at` | timestamptz not null | `now()` |
| `deleted_at` | timestamptz null | soft delete |

Constraint `posts_has_content`: at least one of `body` / `image_path` is non-blank after trimming.
An `is not null` test would be wrong — an empty string satisfies it, admitting content-free posts.
Constraint `posts_pub_needs_label`: `pub_id is null or place_label` is non-blank after trimming.
Index on `(created_at desc)` and `(author_id, created_at desc)`.

No foreign key to `pint_entries` — posts are standalone.

**`post_cheers`** — the feed reaction (see Part C for why the friend nudge had to be renamed to
free this name). `(post_id, user_id)` composite primary key, `created_at`. One per user per post;
the RPC toggles. No separate `(post_id)` index — the primary key's leading column already serves it.

**`post_comments`** — `id`, `post_id` (cascade), `author_id` (cascade), `body` not null
(`char_length between 1 and 280`), `created_at`, `deleted_at`. Index on `(post_id, created_at)`.

**`comment_mentions`** — `(comment_id, mentioned_user_id)` composite primary key. Structured at
write time rather than parsed on read, so rendering and any future notification work is cheap.

### Location

`place_label` is always the string shown in the feed ("Prague", "The Dead Poet"). `pub_id` is set
**only** when the tag is a specific venue, so city tags create no `pubs` row and no junk data.

The picker uses `MKLocalSearchCompleter` for **text search only**, which returns both cities and
venues without device location. `LocationService` stays unreachable and no location permission is
restored. When a result maps to an existing pub row it links via `pub_id`; otherwise only the label
is stored.

### Photos

Photo library only, via `PhotosPicker` — the existing `NSPhotoLibraryUsageDescription` covers it and
no camera permission is needed. Images run through the existing `ImageResizer` before upload.

New `post-images` storage bucket mirroring `avatars`: writes restricted to the uploader's own
folder (`{user_id}/…`), reads gated through the feed RPCs.

### RPCs

| RPC | Purpose |
|---|---|
| `create_post(body, image_path, place_label, pub_id)` | Validates content present, sanitises body, rate-limited |
| `delete_post(post_id)` | Author only; sets `deleted_at` |
| `feed_page(before timestamptz, before_id uuid, limit int)` | Friends-only, block-aware; compound `(created_at, id)` keyset cursor so tied timestamps cannot skip rows; `avatar_path` gated on the owner's privacy setting |
| `toggle_post_cheers(post_id)` | Insert or delete; returns new state + count |
| `add_comment(post_id, body, mentioned_user_ids[])` | Validates mentions are accepted friends |
| `delete_comment(comment_id)` | Author only; soft delete |
| `post_comments_page(post_id, before, before_id, limit)` | Block-aware |
| `report_post(post_id, category, details)` | Into the existing `reports` queue |
| `report_comment(comment_id, category, details)` | Into the existing `reports` queue |

All visibility predicates go through the existing `is_accepted_friend()` helper and must exclude
rows where either direction has a `blocks` entry. Every write calls `enforce_rate_limit`.

### Moderation

Non-optional for submission. Today only `report_user` exists.

- `report_post` / `report_comment` feed the existing `reports` queue (`open → reviewing →
  actioned → dismissed`)
- `blocks` hides posts, comments **and** Cheers in both directions
- Authors can delete their own posts and comments
- Comment and post bodies pass through the existing `ProfileTextSanitizer` (control, format,
  zero-width and bidi characters stripped)
- Rate limits on post, comment and Cheers via `enforce_rate_limit`
- **`docs/MODERATION.md` must be rewritten.** It currently states "No public posts, comments,
  direct messages, anonymous chat, or image feeds in the MVP", which becomes false the moment this
  ships. That document backs the 17+ age rating, so it is a submission blocker, not a formality.

### Client

New `CheekyPint/Features/Feed/`:

- `FeedView` — tab 2 of 4, paginated list, pull to refresh
- `FeedPostCard` — author, avatar, photo, body, place label, Cheers toggle, comment count
- `ComposePostSheet` — text field, `PhotosPicker`, place picker, post button
- `PlacePickerSheet` — `MKLocalSearchCompleter` search over cities and venues
- `PostCommentsSheet` — comment list, composer, mention autocomplete over accepted friends
- `FeedViewModel`, `FeedRepository` (alongside the other repositories in `Core/Database`)

`MainTabView` gains a Feed tab (`Logger | Feed | Leaderboard | Settings`). Cheers renders as a
clinking-beers glyph with a count.

`Theme.Palette.accent` drives the Cheers active state; no new colours.

## Part C — rename the friend nudge

`Cheers` currently means two unrelated things, and the feed reaction would be a third:

1. **`WelfareMonitor.PintFeedbackTone.cheers`** / `WelfareMonitor.cheersMessage` — the post-log
   confirmation copy ("Pint logged. Cheers.") that alternates with the welfare nudge. This is
   responsible-drinking logic and is **left completely untouched**. It is also why
   `HomeViewModel`, `corecheck/main.swift`, `WelfareMonitor.swift` and `SafetyAndTotalsTests.swift`
   match a grep for "cheers" but must **not** be renamed.
2. **The friend nudge** — a shipped, tested, Facebook-poke-style gesture on the leaderboard.
3. **The new feed reaction** — what this spec adds.

(2) is renamed to **Nudge** so (3) can own the Cheers name. This is a mechanical rename of roughly
90 references, not a rewrite — the feature keeps working exactly as it does today.

| Location | Refs | Change |
|---|---|---|
| `Features/Leaderboard/LeaderboardView.swift` | 35 | state, alerts, confirmation copy |
| `Features/Leaderboard/LeaderboardRowView.swift` | 16 | `CheersButtonState` → `NudgeButtonState` |
| `Core/Demo/DemoWorld.swift` | 17 | `DemoCheers` → `DemoNudge`, seeded state |
| `Core/Database/FriendsRepository.swift` | 8 | `sendCheers` → `sendNudge`, `fetchReceivedCheers` → `fetchReceivedNudges` |
| `Core/Database/RPCContracts.swift` | 5 | `CheersParams`/`CheersDTO` → `NudgeParams`/`NudgeDTO` |
| `CheekyPintUITests/OnboardingUITests.swift` | 5 | `testCanCheersBackFromLeaderboard` → `testCanNudgeBackFromLeaderboard`, button labels |
| `supabase/migrations/20260803000000_cheers.sql` | — | becomes `..._nudges.sql`; `cheers` table → `nudges`, `send_cheers` → `send_nudge` |
| `supabase/tests/rls_rpc_suite.sql` | — | rename the covered RPC |

User-facing copy changes: "Cheers back" → "Nudge back", "Cheers sent to X" → "Nudge sent to X",
"Couldn't send Cheers" → "Couldn't send Nudge".

Because the migration is still uncommitted and unapplied to any hosted database, the table can be
renamed in place rather than needing a follow-up migration.

## Testing

- **`CheekyPintCore`**: mention parsing (extracting `@username` from a comment body) and feed
  page-cursor logic as pure functions, unit tested there.
- **`supabase/tests/rls_rpc_suite.sql`** extended: a non-friend sees no posts; a blocked user's
  posts, comments and Cheers vanish in both directions; mentioning a non-friend is rejected;
  soft-deleted posts and comments disappear from every read path; rate limits trigger; a
  non-author cannot delete.
- **App tests**: `FeedViewModel` paging and Cheers optimistic-toggle rollback on failure.
- Existing suites must stay green: 54 `CheekyPintCore` tests, app unit tests.

## Risks

- **Moderation scope is the real submission gate**, not the feed code. Guideline 1.2 requires
  filtering, reporting, blocking and published contact info. `support@cheekypint.app` is currently
  a placeholder in `MODERATION.md` and needs to be real.
- Reactive-only moderation (report-driven, no proactive image scanning) is the plan. Acceptable for
  a friends-only feed; would not be for a public one.
- The uncommitted deep-link removal in the working tree touches `Info.plist` and
  `SessionController`. It should be resolved before or alongside this work to avoid conflicts.

## Sequencing

1. Part A (instant logging) — small, independent, removes the licence problem immediately
2. Part C (nudge rename) — mechanical, unblocks the Cheers name, keeps existing tests green
3. Migrations + RPCs + RLS + storage bucket, with the SQL test suite
4. Repository + view models
5. Screens
6. Moderation RPCs and the `MODERATION.md` rewrite

Each step must leave the existing suites green (54 `CheekyPintCore` tests, 8 app tests) before the
next begins.
