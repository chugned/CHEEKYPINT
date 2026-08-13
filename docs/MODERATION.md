# Moderation

Because users can upload profile photos and text, CheekyPint includes basic UGC protection while
keeping the social surface deliberately small to make moderation tractable.

## Constrained surface (by design)

No public posts or comments, and no direct-message or anonymous-chat surface. The feed is
**friends-only**, not public, for everything except post *photos* — see the callout below. User-
visible UGC is: display name, username, bio, avatar, city, pub suggestions (name/address), and —
as of the friends-only feed — post bodies, place labels, post photos, comments, and @-mentions
within comments.

Post metadata, bodies, place labels and comments are friends-only, enforced server-side (not just
in the client) via `feed_page` / `post_comments_page` and the checks below:

- A post is visible to its author or to an accepted friend of the author, and never to anyone the
  author has blocked (or who has blocked the author) — `public.feed_page`
  (`supabase/migrations/20260811000500_rpc_feed_posts.sql:160`), gated through
  `public.is_accepted_friend`, which itself checks `not public.is_blocked(a, b)`
  (`supabase/migrations/20260101000600_security_helpers.sql:26-41`).
- The comment/cheers entry points (`toggle_post_cheers`, `add_comment`, `post_comments_page`)
  re-derive the same visibility from `public.can_view_post` rather than trusting that a caller
  holding a post id may act on it (`supabase/migrations/20260811000600_rpc_feed_social.sql:5-19`,
  used at lines 33, 82, 204). `delete_comment` is the one entry point that does **not** call
  `can_view_post`; its own `author_id = v_uid` check (below) is strictly narrower, so this is not a
  gap. `post_comments_page` additionally excludes any comment whose author the viewer has blocked,
  even within a thread the viewer can otherwise see
  (`supabase/migrations/20260811000600_rpc_feed_social.sql:205`).
- @-mentions in comments are restricted to people the commenter is an accepted friend of —
  mentioning a non-friend raises `Can only mention friends`
  (`supabase/migrations/20260811000600_rpc_feed_social.sql:106-114`). A friend who cannot
  independently see the post being commented on (e.g. the post's author has blocked them) is
  **silently dropped** from the mention rather than raising: raising would let the commenter probe
  a private edge of someone else's social graph — a target's friendship with the *commenter* is
  something the commenter already knows, but a rejection distinguishable from "not your friend"
  would additionally disclose that the target and the post's author have some hidden relationship
  (a block, or a visibility setting) the commenter has no way to see directly. Mention
  notifications are an explicit non-goal, so the dropped mention has no other observable effect.
- Posts and post tables (`posts`, `post_cheers`, `post_comments`, `comment_mentions`) have RLS
  enabled with no policies and all privileges revoked from `public`/`anon`/`authenticated`: every
  read and write goes through a `security definer` RPC, never a direct table grant
  (`supabase/migrations/20260811000100_feed_tables.sql:93-101`).
- Authors can soft-delete their own posts and comments (`deleted_at`); a post's author cannot
  delete another user's comment on that post — `delete_comment` only matches
  `author_id = v_uid`, with no clause referencing the post's owner at all
  (`supabase/migrations/20260811000600_rpc_feed_social.sql:129-152`), and `delete_post` is likewise
  gated on `author_id = v_uid` (`supabase/migrations/20260811000500_rpc_feed_posts.sql:78-86`).
  Concretely: if a friend posts something abusive as a *comment* on your post, you cannot remove
  it yourself. Blocking that commenter only hides the comment from you specifically —
  `post_comments_page`'s block filter is keyed on the viewer
  (`supabase/migrations/20260811000600_rpc_feed_social.sql:205`), so every other friend who can
  see the thread still sees the comment unchanged. The only current remedies are deleting the
  whole post (which takes the comment down with it) or reporting the comment via `report_comment`
  for a moderator to act on. Post-owner comment moderation is deferred, not shipped.

**Known tradeoff — post photos are unlisted, not access-controlled.** The `post-images` storage
bucket is created with `public = true`
(`supabase/migrations/20260811000200_feed_storage.sql:12-14`), so any object is retrievable via
`GET /storage/v1/object/public/post-images/<uid>/<file>` with no `Authorization` header and no RLS
evaluation — the `post_images_read_authenticated` policy in the same file only governs the
authenticated route, which the app doesn't use for reads. Protection comes entirely from
`feed_page` deciding whether to hand a client the `image_path` and from filenames carrying an
unguessable random component: friends-only access control never actually gates the photo bytes
themselves. `delete_post` sets `deleted_at` and never removes the storage object
(`supabase/migrations/20260811000500_rpc_feed_posts.sql:78-86`), so a soft-deleted post's photo
stays publicly fetchable forever once its URL has escaped (screenshot, forwarded link, scraped
before a block). This is the same documented tradeoff as the avatars bucket
([PRIVACY.md](PRIVACY.md)); a hardening pass would move both to short-lived signed URLs minted
after RPC authorisation.

## User tools

- **Block** — overrides all visibility both directions; tears down friendship + pending requests;
  also hides the blocker's feed posts and comments from the blocked party (and vice versa), and
  removes the ability to cheer, comment, or be mentioned across the block, per the visibility
  rules above. Two narrow aggregate residues survive a block rather than being retroactively
  scrubbed: `feed_page`'s `cheers_count` still counts a cheer the now-blocked party left before
  the block (no identity is exposed, only the total), and `post_comments_page`'s
  `mentioned_user_ids` array can still contain a blocked user's UUID from a mention made before
  the block (an opaque id, not their profile). `feed_page`'s `comment_count` is deliberately *not*
  on this list: it is filtered by the same block and soft-deleted-profile rules as
  `post_comments_page` itself (`supabase/migrations/20260811000500_rpc_feed_posts.sql:143-154`,
  mirroring `20260811000600_rpc_feed_social.sql:203-206`), so the number a feed row shows always
  agrees with what the thread read actually returns — it cannot advertise a comment the reader
  will then find the thread empty of.
- **Report** — one shared moderation queue (`public.reports`) covers accounts, posts, and
  comments:
  - `report_user(target, category, details)` — accounts
    (`supabase/migrations/20260101000800_rpc_social.sql:204-228`).
  - `report_post(post_id, category, details)` — a specific post; requires the caller to be able to
    view the post, rejects self-reports, and links `reports.post_id`
    (`supabase/migrations/20260811000700_rpc_feed_reports.sql:4-37`).
  - `report_comment(comment_id, category, details)` — a specific comment; same visibility and
    self-report checks, links `reports.comment_id`
    (`supabase/migrations/20260811000700_rpc_feed_reports.sql:39-76`).
  - Categories include inappropriate image/text — plus a feed-specific
    `inappropriate_post_image` value so a moderator triaging the queue isn't misled by
    `inappropriate_profile_image` on a post report
    (`supabase/migrations/20260811000300_report_category_post_image.sql`) — harassment,
    impersonation, underage concern, other. All three RPCs share the `report` rate limit.
  - A report always names an account **when it is filed** — `reported_user_id` is enforced non-null
    at insert by the `reports_stamp_subject_key` trigger
    (`supabase/migrations/20260101000300_social_tables.sql`) — and may additionally target at most one
    *content* item, a post or a comment, never both (`reports_single_target` check,
    `supabase/migrations/20260811000400_feed_reports.sql`). The column itself is nullable, for one
    reason only: a report **outlives both accounts involved in it**. On deletion of the reported
    account, `reported_user_id`, `post_id` and `comment_id` are set to NULL and the row is kept, with a
    stable pseudonym for the former subject in `reported_user_key`. On deletion of the *reporting*
    account, `reporter_id` is set to NULL, `reporter_key` keeps the pseudonym — and `details`, the
    reporter's own free text, is **erased**, guaranteed by the `report_details_erased_with_reporter`
    CHECK rather than by the trigger that satisfies it, so the erasure cannot silently fail to happen.
    The two keys are in separate namespaces, so the roles cannot be joined across de-linked rows.
    Neither key identifies a person across accounts — see
    [MODERATION_PROCESS.md](MODERATION_PROCESS.md) §6, which is explicit about what they do and do not
    achieve, and about what erasing `details` costs for an account-level report.
- **Remove friend** — ends the relationship without blocking.

## Preventive controls

- Length limits + sanitisation on display name (40), bio (160), city (60), note (280); control/
  format/zero-width/bidi characters stripped client-side (`ProfileTextSanitizer`, tested) — this
  covers every Unicode `Cf` (format, ~160 codepoints) and `Cc` (control) scalar. There is no
  profile-update RPC: `profiles_update_self` (`supabase/migrations/20260101000700_rls_policies.sql:34-37`)
  permits direct DML from the client with only an ownership check (`id = auth.uid()`), so this
  sanitisation is **client-side only** and bypassable by a client that skips it — the same class of
  gap the feed-body sanitiser below closes for post/comment text, just not yet closed here.
- Username validation + reserved-word list to reduce impersonation (`admin`, `support`, …) — this
  control is **client-side only** (`CheekyPintCore`'s `UsernameValidator`
  (`CheekyPintCore/Sources/CheekyPintCore/Validation/UsernameValidator.swift`)). The database's own
  `username_format` check (`supabase/migrations/20260101000200_core_tables.sql:11-12`) enforces
  only a character-set/length regex, with no reserved-word awareness, and `profiles_update_self`
  permits direct DML — the same client-only-sanitiser bypass disclosed two bullets above for the
  display-name/bio sanitiser applies here too: a client that skips `UsernameValidator` can claim
  `admin` or `support` outright.
- Resized avatars only; storage writes restricted to the user's own folder.
- Pub suggestions: `pubs.name` has a database-enforced length cap
  (`pub_name_length` check, 1–120 chars, `supabase/migrations/20260101000400_pub_tables.sql:10`),
  but `formatted_address` has no length cap beyond the column type. Neither has a rate limit or a
  sanitiser — `pubs_insert_authenticated`
  (`supabase/migrations/20260101000700_rls_policies.sql:84-85`) only checks
  `created_by = auth.uid()`. Unlike feed posts/comments, this is direct RLS-governed DML with no
  RPC in front of it at all.
- Feed post bodies (≤500 chars) and comment bodies (≤280 chars) run through a server-side
  sanitiser, `public.strip_ugc_control_chars`
  (`supabase/migrations/20260811000100_feed_tables.sql:12-28`), enforced in the database itself —
  not only in the client — because a client-only sanitiser is bypassable by calling the RPC
  directly. Its coverage is **narrower** than `ProfileTextSanitizer`: it strips ASCII control
  characters (`Cc`, via `[[:cntrl:]]`) plus a named, hand-picked set of 16 zero-width/bidi-override
  codepoints (U+200B–U+200F, U+202A–U+202E, U+FEFF, U+2060, U+2066–U+2069). It does not strip the
  Unicode `Cf` (format) category generally, so characters such as U+00AD (soft hyphen), U+061C,
  U+180E, U+206A–U+206F, U+FFF9–U+FFFB, and the U+E0020–U+E007F tag-character block pass through
  server-side unchanged. Parity with the client sanitiser is partial, not full.
- Rate limits: `public.enforce_rate_limit` inserts one row into `rate_limit_events` per *call* and
  rejects once the caller's count for that action within the trailing window reaches the max
  (`supabase/migrations/20260101000600_security_helpers.sql:100-127`). Actions:
  `friend_token_regenerate`, `friend_token_resolve`, `friend_request`, `report`, `pint_create`,
  `session_create`, `session_join`, `clink_create`, `nudge_send` (all pre-existing), plus the
  following new feed actions: `post_create` (20/hr), `post_delete` (60/hr), `post_comment` (60/hr),
  `comment_delete` (60/hr), and `cheers_toggle` (120/hr) for cheering/un-cheering a post.

## Admin / back office

**The runbook is [MODERATION_PROCESS.md](MODERATION_PROCESS.md)** — statuses and what each commits
you to, the SQL the operator pastes into the Supabase dashboard, per-category handling, enforcement
actions, retention, and how the queue meets App Store Review guideline 1.2's "timely response" limb.
This section covers only what the *schema* provides.

- `reports` is a queue (`open → reviewing → actioned → dismissed`) with indexes on
  `(status, created_at)`, both party ids, both party keys, and `post_id` / `comment_id` for
  content reports (`supabase/migrations/20260101000300_social_tables.sql`,
  `supabase/migrations/20260811000400_feed_reports.sql`).
- A **de-linked** report is invisible to every client: `reports_select_own` is
  `reporter_id = auth.uid()`, which yields NULL rather than true once that column is NULL, so a row
  whose reporter has left is readable only by the operator in the dashboard. That is deliberate and
  asserted — the two tidier spellings of that policy (`is not distinct from`, or an added
  `or reporter_id is null`) would each leak those rows to clients.
- `public.review_report(report_id, status)` is the only supported transition
  (`supabase/migrations/20260813000100_review_report.sql`). Service role only: revoked from `public`,
  `anon` and `authenticated`, granted to `service_role`, and asserted by function privilege in the
  RLS/RPC suite. It stamps `reviewed_at` for `actioned`/`dismissed`, refuses a transition to `open`,
  and refuses an unknown id. It records a decision and deliberately performs **no** enforcement.
- Until that function existed the queue was **write-only**: nothing in the schema ever set
  `reports.status` or `reports.reviewed_at`, so `purge_resolved_reports` — which matches on both —
  had never deleted a row, and the retention commitment in
  `docs/legal/DATA_RETENTION_POLICY.md` was unenforceable in principle. A CHECK constraint
  (`report_reviewed_at_matches_status`) now makes the resolved-but-unstamped state unrepresentable, so
  a hand-typed dashboard `UPDATE` cannot silently recreate it.
- There is no admin **read** RPC and no moderator role. The operator reads the queue in the Supabase
  dashboard as the project owner, where RLS does not apply to them; the table's only policy,
  `reports_select_own`, serves reporters reading their own filed reports.
- An administrator can disable an abusive profile by setting `profiles.deleted_at` via the service
  role / an internal tool. This is complete on every **read** path: `pr.deleted_at is null` gates
  the profile out of `feed_page`, `post_comments_page`, and friend-facing lookups alike. It is
  **not** complete on the write side — `create_post`, `add_comment`, and `toggle_post_cheers` only
  check `auth.uid() is null` and (for comments/cheers) `can_view_post`; none of them re-checks
  whether the *caller's own* `profiles.deleted_at` is set. A disabled account's JWT is untouched
  (disabling is a `profiles` update, not an `auth.users` deletion), so a disabled account can still
  post, comment, and cheer — it simply becomes invisible to others while doing so. A dedicated
  admin RPC, a caller-side `deleted_at` guard, and an audit log are a fast-follow.
- Support contact: `support@cheekypint.app` (placeholder).

## Escalation

Underage-concern and impersonation reports should be triaged first. Serious safety reports may
warrant immediate profile disable pending review.
