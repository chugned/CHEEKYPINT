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

-- Report retention. Two classes of report, two clocks, one scheduled job — deliberately one
-- function so there is a single place to reason about how long a moderation record lives, and a
-- single cron entry to get wrong. The name is now marginally narrower than the behaviour (it also
-- removes retained-but-never-resolved rows); it is kept because docs/RELEASE_CHECKLIST.md,
-- docs/DPIA.md and docs/RECORDS_OF_PROCESSING.md all cite it by name.
--
-- 1. RESOLVED reports: p_older_than after `reviewed_at`. Unchanged in intent, but reachable for the
--    first time — until public.review_report existed (20260813000100_review_report.sql) nothing in
--    the entire schema ever set `status` or `reviewed_at`, so this branch matched zero rows for its
--    whole life and the 18-month commitment in docs/legal/DATA_RETENTION_POLICY.md could not be
--    honoured. The suite now asserts that it actually deletes a row.
--
-- 2. RETAINED reports whose subject is gone and which were never resolved: p_retained_older_than
--    after `created_at`. These have no `reviewed_at` to key off (see the
--    report_reviewed_at_matches_status constraint), so without this branch a report about a departed
--    account that nobody ever triaged would be kept forever — indefinite retention, which is what
--    Art. 5(1)(e) forbids and which would make the retention decision itself indefensible.
--
--    24 months from `created_at` is chosen so the two classes land in roughly the same place: a
--    report resolved ~6 months after filing and then kept 18 months from resolution is destroyed
--    about 24 months after filing, so both classes stay inside the 12–24 month window published in
--    docs/legal/DATA_RETENTION_POLICY.md and there is one outward-facing figure rather than two.
--    THE NUMBER IS AN ENGINEERING DEFAULT CHOSEN FOR CONSISTENCY, NOT LEGAL ADVICE, and requires
--    counsel sign-off before launch — the relevant limitation periods for the claims this retention
--    is meant to defend are a lawyer's question, not a schema author's.
--
--    Branch 2 keys on `reported_user_id is null`, so it covers the FULLY de-linked row — no reporter
--    and no subject — as well as the subject-only case. That matters since reporter_id also became
--    `on delete set null` (20260101000300_social_tables.sql): a report both of whose parties have
--    left, and which nobody ever reviewed, is the one row with no living party to trigger any other
--    cleanup, and it must not become an immortal orphan. Asserted in the suite.
--
-- Not covered, on purpose: reports about a LIVE account that were never resolved — whether or not
-- their REPORTER has since left. They remain unbounded (docs/DPIA.md §3.8 records this as a choice).
-- The reasoning is the same in both shapes: the fix for a never-triaged report about a live account
-- is to triage it, and a purge would quietly destroy an open safety report rather than surface it.
-- A reporter having departed does not make the complaint about a live account less worth reading —
-- it makes it harder to follow up, which is an argument for triaging sooner, not for deleting. Note
-- the consequence honestly: such a row keeps its category, dates and content links indefinitely,
-- though its `details` has already been erased with its reporter.
create or replace function public.purge_resolved_reports(
  p_older_than interval default interval '18 months',
  p_retained_older_than interval default interval '24 months'
)
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
     where (
             -- 1. resolved: clock runs from the review outcome
             status in ('actioned', 'dismissed')
             and reviewed_at < now() - p_older_than
           )
        or (
             -- 2. retained + never resolved: clock runs from when the report was filed
             reported_user_id is null
             and reviewed_at is null
             and created_at < now() - p_retained_older_than
           )
    returning 1
  )
  select count(*)::int into v_count from gone;

  return v_count;
end;
$$;

comment on function public.purge_resolved_reports(interval, interval) is
  'Retention purge for public.reports: resolved reports p_older_than after reviewed_at, plus '
  'reports whose subject account was deleted and which were never resolved, p_retained_older_than '
  'after created_at. Service role only. Both periods require counsel sign-off '
  '(docs/legal/DATA_RETENTION_POLICY.md).';

-- Maintenance surface: service role only, matching prune_rate_limit_events
-- (20260101000600_security_helpers.sql:140). No client, including `authenticated`, may run a
-- retention purge directly.
revoke all on function public.purge_soft_deleted_posts(interval) from public, anon, authenticated;
revoke all on function public.purge_soft_deleted_comments(interval) from public, anon, authenticated;
revoke all on function public.purge_soft_deleted_pint_entries(interval) from public, anon, authenticated;
revoke all on function public.purge_resolved_reports(interval, interval) from public, anon, authenticated;
