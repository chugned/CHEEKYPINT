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
  (`supabase/migrations/20260811000500_rpc_feed_posts.sql:150`), gated through
  `public.is_accepted_friend`, which itself checks `not public.is_blocked(a, b)`
  (`supabase/migrations/20260101000600_security_helpers.sql:26-41`).
- The comment/cheers entry points (`toggle_post_cheers`, `add_comment`, `post_comments_page`)
  re-derive the same visibility from `public.can_view_post` rather than trusting that a caller
  holding a post id may act on it (`supabase/migrations/20260811000600_rpc_feed_social.sql:5-19`,
  used at lines 33, 81, 195). `delete_comment` is the one entry point that does **not** call
  `can_view_post`; its own `author_id = v_uid` check (below) is strictly narrower, so this is not a
  gap. `post_comments_page` additionally excludes any comment whose author the viewer has blocked,
  even within a thread the viewer can otherwise see
  (`supabase/migrations/20260811000600_rpc_feed_social.sql:196`).
- @-mentions in comments are restricted to people the commenter is an accepted friend of, **and**
  who can independently see the post being commented on — mentioning a friend into a thread they
  cannot view is rejected (`supabase/migrations/20260811000600_rpc_feed_social.sql:98-104`).
- Posts and post tables (`posts`, `post_cheers`, `post_comments`, `comment_mentions`) have RLS
  enabled with no policies and all privileges revoked from `public`/`anon`/`authenticated`: every
  read and write goes through a `security definer` RPC, never a direct table grant
  (`supabase/migrations/20260811000100_feed_tables.sql:93-101`).
- Authors can soft-delete their own posts and comments (`deleted_at`); a post's author cannot
  delete another user's comment on that post — `delete_comment` only matches
  `author_id = v_uid`, with no clause referencing the post's owner at all
  (`supabase/migrations/20260811000600_rpc_feed_social.sql:120-143`), and `delete_post` is likewise
  gated on `author_id = v_uid` (`supabase/migrations/20260811000500_rpc_feed_posts.sql:78-86`).

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
  the block (an opaque id, not their profile).
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
  - `reported_user_id` is `not null` on every row, so a report always targets an account; it may
    additionally target at most one *content* item — a post or a comment, never both
    (`reports_single_target` check, `supabase/migrations/20260811000400_feed_reports.sql:10-12`).
- **Remove friend** — ends the relationship without blocking.

## Preventive controls

- Length limits + sanitisation on display name (40), bio (160), city (60), note (280); control/
  format/zero-width/bidi characters stripped client-side (`ProfileTextSanitizer`, tested) — this
  covers every Unicode `Cf` (format, ~160 codepoints) and `Cc` (control) scalar. There is no
  profile-update RPC: `profiles_update_self` (`supabase/migrations/20260101000700_rls_policies.sql:34-37`)
  permits direct DML from the client with only an ownership check (`id = auth.uid()`), so this
  sanitisation is **client-side only** and bypassable by a client that skips it — the same class of
  gap the feed-body sanitiser below closes for post/comment text, just not yet closed here.
- Username validation + reserved-word list to reduce impersonation (`admin`, `support`, …).
- Resized avatars only; storage writes restricted to the user's own folder.
- Pub suggestions (`pubs.name`, `formatted_address`) have no length cap beyond the column type, no
  rate limit, and no sanitiser — `pubs_insert_authenticated`
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

- `reports` table is a queue (`open → reviewing → actioned → dismissed`) with indexes on
  `(status, created_at)`, `reported_user_id`, and now also `post_id` / `comment_id` for content
  reports (`supabase/migrations/20260811000400_feed_reports.sql:14-15`).
- An administrator can disable an abusive profile by setting `profiles.deleted_at` (removes it
  from every surface) via the service role / an internal tool. A dedicated admin RPC and audit
  log are a fast-follow.
- Support contact: `support@cheekypint.app` (placeholder).

## Escalation

Underage-concern and impersonation reports should be triaged first. Serious safety reports may
warrant immediate profile disable pending review.
