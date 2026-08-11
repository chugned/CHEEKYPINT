-- Retention purges. docs/legal/DATA_RETENTION_POLICY.md promises soft-deleted content is purged
-- within 30 days and resolved reports kept 12-24 months; nothing enforced that until now — the
-- only scheduled job in the schema was prune_rate_limit_events. These are maintenance functions:
-- revoked from `authenticated` and intended for a scheduled service-role invocation.
--
-- Order matters: enqueue the storage object BEFORE deleting the row, because the row holds the
-- only copy of image_path.
--
-- Deliberate cascade: post_cheers.post_id and post_comments.post_id are both
-- `references public.posts (id) on delete cascade` (20260811000100_feed_tables.sql:59,70). When
-- this function hard-deletes an aged, soft-deleted post, that FK silently takes every comment and
-- cheer on it with it — including a comment from a user who never soft-deleted anything and whose
-- content has no retention clock of its own (e.g. B comments on A's post; A soft-deletes the post;
-- B's untouched comment is destroyed 30 days later when this function purges A's post row). This
-- is intended, not an oversight: a comment or cheer has no meaning or surface to appear on once
-- its post is gone, so it is treated as part of the post rather than independently retained. It IS
-- another user's personal data being erased as a side effect of someone else's action, which is
-- why it is documented here and in docs/legal/DATA_RETENTION_POLICY.md rather than left implicit.

create or replace function public.purge_soft_deleted_posts(p_older_than interval default interval '30 days')
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count int;
begin
  -- A scalar function call in the SELECT list of a set-returning query is evaluated once per
  -- row the FROM/WHERE clause produces — not once total — because it is not constant-foldable
  -- (it references the per-row column p.image_path). Confirmed empirically with >1 qualifying
  -- row before relying on it here.
  perform public.enqueue_storage_object('post-images', p.image_path)
     from public.posts p
    where p.deleted_at is not null
      and p.deleted_at < now() - p_older_than
      and p.image_path is not null;

  with gone as (
    delete from public.posts
     where deleted_at is not null
       and deleted_at < now() - p_older_than
    returning 1
  )
  select count(*)::int into v_count from gone;

  return v_count;
end;
$$;

create or replace function public.purge_soft_deleted_comments(p_older_than interval default interval '30 days')
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count int;
begin
  -- No enqueue: post_comments carries no storage object of its own.
  with gone as (
    delete from public.post_comments
     where deleted_at is not null
       and deleted_at < now() - p_older_than
    returning 1
  )
  select count(*)::int into v_count from gone;

  return v_count;
end;
$$;

create or replace function public.purge_soft_deleted_pint_entries(p_older_than interval default interval '30 days')
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count int;
begin
  -- No enqueue: pint_entries carries no storage object of its own.
  with gone as (
    delete from public.pint_entries
     where deleted_at is not null
       and deleted_at < now() - p_older_than
    returning 1
  )
  select count(*)::int into v_count from gone;

  return v_count;
end;
$$;

create or replace function public.purge_resolved_reports(p_older_than interval default interval '18 months')
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count int;
begin
  with gone as (
    delete from public.reports
     where status in ('actioned', 'dismissed')
       and reviewed_at < now() - p_older_than
    returning 1
  )
  select count(*)::int into v_count from gone;

  return v_count;
end;
$$;

-- Maintenance surface: service role only, matching prune_rate_limit_events
-- (20260101000600_security_helpers.sql:140). No client, including `authenticated`, may run a
-- retention purge directly.
revoke all on function public.purge_soft_deleted_posts(interval) from public, anon, authenticated;
revoke all on function public.purge_soft_deleted_comments(interval) from public, anon, authenticated;
revoke all on function public.purge_soft_deleted_pint_entries(interval) from public, anon, authenticated;
revoke all on function public.purge_resolved_reports(interval) from public, anon, authenticated;
