# Moderation

Because users can upload profile photos and text, CheekyPint includes basic UGC protection while
keeping the social surface deliberately small to make moderation tractable.

## Constrained surface (by design)

No public posts, comments, or direct messages: the feed is **friends-only**, not public, and there
is no direct-message or anonymous-chat surface. User-visible UGC is: display name, username, bio,
avatar, pub suggestions, and — as of the friends-only feed — post bodies, post photos, comments,
and @-mentions within comments.

Feed visibility is enforced server-side, not just in the client:

- A post is visible to its author or to an accepted friend of the author, and never to anyone the
  author has blocked (or who has blocked the author) — `public.feed_page`
  (`supabase/migrations/20260811000500_rpc_feed_posts.sql:150`), gated through
  `public.is_accepted_friend`, which itself checks `not public.is_blocked(a, b)`
  (`supabase/migrations/20260101000600_security_helpers.sql:26-41`).
- Every comment/cheers entry point re-derives the same visibility from `public.can_view_post`
  rather than trusting that a caller holding a post id may act on it
  (`supabase/migrations/20260811000600_rpc_feed_social.sql:5-19`, used at lines 33, 81, 195).
  `post_comments_page` additionally excludes any comment whose author the viewer has blocked, even
  within a thread the viewer can otherwise see (`supabase/migrations/20260811000600_rpc_feed_social.sql:196`).
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

## User tools

- **Block** — overrides all visibility both directions; tears down friendship + pending requests;
  also removes the blocked party's ability to see, comment on, cheer, or be mentioned in the
  blocker's feed posts (and vice versa), per the visibility rules above.
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
  - A report targets at most one of an account, a post, or a comment
    (`reports_single_target` check, `supabase/migrations/20260811000400_feed_reports.sql:10-12`).
- **Remove friend** — ends the relationship without blocking.

## Preventive controls

- Length limits + sanitisation on display name (40), bio (160), city (60), note (280); control/
  format/zero-width/bidi characters stripped (`ProfileTextSanitizer`, tested).
- Username validation + reserved-word list to reduce impersonation (`admin`, `support`, …).
- Resized avatars only; storage writes restricted to the user's own folder.
- Feed post bodies (≤500 chars) and comment bodies (≤280 chars) run through a server-side
  sanitiser, `public.strip_ugc_control_chars`, that strips the same control/zero-width/bidi
  character classes as `ProfileTextSanitizer` — enforced in the database itself, not only in the
  client, because a client-only sanitiser is bypassable by calling the RPC directly
  (`supabase/migrations/20260811000100_feed_tables.sql:12-28`).
- Rate limits (`public.enforce_rate_limit`, one row per action per hour window unless noted):
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
