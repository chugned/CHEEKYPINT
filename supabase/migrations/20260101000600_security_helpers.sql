-- CheekyPint schema — 06. Security helper functions & rate limiting
--
-- These SECURITY DEFINER helpers are the backbone of the RLS policies. They run as the
-- table owner so they can consult `blocks`/`friendships`/`session_members` without being
-- blocked by (or recursing into) those tables' own RLS. Each locks its search_path and is
-- marked STABLE so the planner can cache within a statement.

-- is_blocked: true if EITHER party has blocked the other. This must be checked before any
-- friendship/leaderboard/session rule.
create or replace function public.is_blocked(a uuid, b uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.blocks
    where (blocker_id = a and blocked_id = b)
       or (blocker_id = b and blocked_id = a)
  );
$$;

-- is_accepted_friend: true if there is an accepted friendship in either direction AND
-- neither party has blocked the other.
create or replace function public.is_accepted_friend(a uuid, b uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select a <> b
     and not public.is_blocked(a, b)
     and exists (
       select 1 from public.friendships f
       where f.status = 'accepted'
         and least(f.requester_id, f.addressee_id) = least(a, b)
         and greatest(f.requester_id, f.addressee_id) = greatest(a, b)
     );
$$;

-- shares_active_session: true if a and b are both currently-joined members of the same
-- active session (and not blocked).
create or replace function public.shares_active_session(a uuid, b uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select a <> b
     and not public.is_blocked(a, b)
     and exists (
       select 1
       from public.session_members ma
       join public.session_members mb on mb.session_id = ma.session_id
       join public.pub_sessions s on s.id = ma.session_id
       where ma.user_id = a and mb.user_id = b
         and ma.left_at is null and mb.left_at is null
         and s.status = 'active'
     );
$$;

-- can_view_profile: encapsulates the profile-open rule used by RLS and RPCs. Self always;
-- a friend only when their profile_visibility = 'friends'; never when blocked.
create or replace function public.can_view_profile(viewer uuid, target uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when viewer = target then true
    when public.is_blocked(viewer, target) then false
    when public.is_accepted_friend(viewer, target) then coalesce(
      (select ps.profile_visibility = 'friends'
         from public.privacy_settings ps where ps.user_id = target),
      false)
    else false
  end;
$$;

-- Rate limiting -------------------------------------------------------------------------
create table public.rate_limit_events (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  action text not null,
  created_at timestamptz not null default now()
);

create index rate_limit_events_lookup_idx
  on public.rate_limit_events (user_id, action, created_at desc);

comment on table public.rate_limit_events is 'Append-only log used to enforce per-user action rate limits.';

-- enforce_rate_limit: raises if the caller has performed `action` at least `max_count`
-- times within `window`; otherwise records this attempt. Call at the top of sensitive RPCs.
create or replace function public.enforce_rate_limit(p_action text, p_max_count int, p_window interval)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_count int;
begin
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  select count(*) into v_count
  from public.rate_limit_events
  where user_id = v_uid
    and action = p_action
    and created_at > now() - p_window;

  if v_count >= p_max_count then
    raise exception 'Rate limit exceeded for action %', p_action
      using errcode = 'P0001', hint = 'Please slow down and try again shortly.';
  end if;

  insert into public.rate_limit_events (user_id, action) values (v_uid, p_action);
end;
$$;

-- Prune old rate-limit rows opportunistically (call from a scheduled job in production).
create or replace function public.prune_rate_limit_events(p_older_than interval default interval '2 days')
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.rate_limit_events where created_at < now() - p_older_than;
$$;

revoke all on function public.enforce_rate_limit(text, int, interval) from public, anon, authenticated;
revoke all on function public.prune_rate_limit_events(interval) from public, anon, authenticated;
