-- Reports already record WHO is being reported. Feed reports also need to say WHICH piece of
-- content, so a moderator can act on one post rather than a whole account.
--
-- Both links are `on delete set null`, NOT cascade. They were cascade until the 2026-08-13 operator
-- decision that a report survives the deletion of the account it is about
-- (20260101000300_social_tables.sql). Cascade here silently defeated that decision: posts.author_id
-- and post_comments.author_id both cascade from profiles
-- (20260811000100_feed_tables.sql:16,52), so deleting an account destroyed that account's posts and
-- comments, and THOSE cascades then destroyed the whole reports row — de-linking reported_user_id
-- would have retained nothing for any content report. Setting the link to NULL instead keeps the
-- moderation record (category, timestamps, the reporter's details, the pseudonymous subject key)
-- and drops only the pointer to content that no longer exists.
--
-- Same effect on the ordinary retention path: purge_soft_deleted_posts / _comments hard-delete aged
-- soft-deleted content, and a report about that content now outlives it rather than being deleted by
-- the content's own 30-day clock. That is intended — the report is the audit record of the
-- moderation decision, and it has its own, longer clock.
--
-- Known limitation, accepted: once both links are NULL, a retained report no longer records whether
-- it was originally about a post, a comment, or the account as a whole. `category` is the only
-- surviving hint. Adding a `target_kind` column would fix that; it was not in scope for the
-- retention decision and is noted in docs/MODERATION_PROCESS.md instead of being done silently.
alter table public.reports
  add column if not exists post_id uuid references public.posts (id) on delete set null,
  add column if not exists comment_id uuid references public.post_comments (id) on delete set null;

-- At most one target: a report is about an account, a post, or a comment.
alter table public.reports
  drop constraint if exists reports_single_target;
alter table public.reports
  add constraint reports_single_target
  check (post_id is null or comment_id is null);

create index if not exists reports_post_idx on public.reports (post_id) where post_id is not null;
create index if not exists reports_comment_idx on public.reports (comment_id) where comment_id is not null;
