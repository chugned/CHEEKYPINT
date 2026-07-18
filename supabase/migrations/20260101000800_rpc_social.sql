-- CheekyPint schema — 08. RPCs: friend tokens, friendships, blocks, reports, reads
--
-- Every function here is SECURITY DEFINER with a locked search_path. They are the ONLY way
-- clients read cross-user data, and they encode the privacy + block rules that RLS keeps
-- structurally simple. All raise on unauthenticated access and validate their inputs.

-- regenerate_friend_token: revoke the caller's active tokens and mint a fresh one.
-- Returns the RAW token ONCE — it is never persisted (only its hash is).
create or replace function public.regenerate_friend_token()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_raw text;
  v_hash text;
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;
  perform public.enforce_rate_limit('friend_token_regenerate', 10, interval '1 hour');

  update public.friend_tokens
    set revoked_at = now()
    where user_id = v_uid and revoked_at is null;

  v_raw := replace(replace(encode(extensions.gen_random_bytes(32), 'base64'), '+', '-'), '/', '_');
  v_raw := replace(v_raw, '=', '');
  v_hash := encode(extensions.digest(v_raw, 'sha256'), 'hex');

  insert into public.friend_tokens (user_id, token_hash) values (v_uid, v_hash);
  return v_raw;
end;
$$;

-- resolve_friend_token: turn a scanned/entered raw token into a SAFE profile preview.
-- Rate-limited to slow enumeration. Never reveals email, city, totals, or anything beyond
-- the minimum needed to decide whether to send a request.
create or replace function public.resolve_friend_token(p_raw_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_hash text;
  v_owner uuid;
  v_profile public.profiles;
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;
  perform public.enforce_rate_limit('friend_token_resolve', 30, interval '1 hour');

  v_hash := encode(extensions.digest(coalesce(p_raw_token, ''), 'sha256'), 'hex');

  select ft.user_id into v_owner
  from public.friend_tokens ft
  where ft.token_hash = v_hash
    and ft.revoked_at is null
    and (ft.expires_at is null or ft.expires_at > now());

  -- Uniform failure for missing/expired/self/blocked, to avoid leaking which case occurred.
  if v_owner is null
     or v_owner = v_uid
     or public.is_blocked(v_uid, v_owner) then
    raise exception 'This code is not valid' using errcode = 'P0002';
  end if;

  select * into v_profile from public.profiles where id = v_owner and deleted_at is null;
  if not found then
    raise exception 'This code is not valid' using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'user_id', v_profile.id,
    'display_name', v_profile.display_name,
    'avatar_path', v_profile.avatar_path
  );
end;
$$;

-- send_friend_request: create a pending request to an already-resolved user.
create or replace function public.send_friend_request(p_addressee uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.friendships;
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;
  if p_addressee = v_uid then raise exception 'Cannot add yourself' using errcode = '22023'; end if;
  if public.is_blocked(v_uid, p_addressee) then
    raise exception 'This code is not valid' using errcode = 'P0002';
  end if;
  perform public.enforce_rate_limit('friend_request', 30, interval '1 hour');

  -- Reuse any existing live edge (idempotent-ish); otherwise create a pending one.
  select * into v_row from public.friendships
  where user_low = least(v_uid, p_addressee)
    and user_high = greatest(v_uid, p_addressee)
    and status in ('pending', 'accepted')
  limit 1;

  if found then
    return jsonb_build_object('friendship_id', v_row.id, 'status', v_row.status);
  end if;

  insert into public.friendships (requester_id, addressee_id, status)
  values (v_uid, p_addressee, 'pending')
  returning * into v_row;

  return jsonb_build_object('friendship_id', v_row.id, 'status', v_row.status);
end;
$$;

-- respond_to_friend_request: only the addressee may accept/decline a pending request.
create or replace function public.respond_to_friend_request(p_friendship_id uuid, p_accept boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.friendships;
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;

  update public.friendships
    set status = case when p_accept then 'accepted'::public.friendship_status else 'declined'::public.friendship_status end,
        responded_at = now()
    where id = p_friendship_id
      and addressee_id = v_uid
      and status = 'pending'
    returning * into v_row;

  if not found then
    raise exception 'Request not found' using errcode = 'P0002';
  end if;
  return jsonb_build_object('friendship_id', v_row.id, 'status', v_row.status);
end;
$$;

-- remove_friend: either party ends an accepted friendship.
create or replace function public.remove_friend(p_other uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;
  update public.friendships
    set status = 'removed', updated_at = now()
    where status in ('pending', 'accepted')
      and user_low = least(v_uid, p_other)
      and user_high = greatest(v_uid, p_other);
end;
$$;

-- block_user: create a block and tear down any friendship. Blocks override everything.
create or replace function public.block_user(p_target uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;
  if p_target = v_uid then raise exception 'Cannot block yourself' using errcode = '22023'; end if;

  insert into public.blocks (blocker_id, blocked_id)
  values (v_uid, p_target)
  on conflict do nothing;

  update public.friendships
    set status = 'removed', updated_at = now()
    where status in ('pending', 'accepted')
      and user_low = least(v_uid, p_target)
      and user_high = greatest(v_uid, p_target);
end;
$$;

create or replace function public.unblock_user(p_target uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;
  delete from public.blocks where blocker_id = v_uid and blocked_id = p_target;
end;
$$;

-- report_user: queue a moderation report.
create or replace function public.report_user(
  p_target uuid,
  p_category public.report_category,
  p_details text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.reports;
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;
  if p_target = v_uid then raise exception 'Cannot report yourself' using errcode = '22023'; end if;
  perform public.enforce_rate_limit('report', 20, interval '1 hour');

  insert into public.reports (reporter_id, reported_user_id, category, details)
  values (v_uid, p_target, p_category, left(coalesce(p_details, ''), 1000))
  returning * into v_row;

  return jsonb_build_object('report_id', v_row.id, 'status', v_row.status);
end;
$$;

-- get_friends: accepted friends with basic, privacy-aware identity fields.
create or replace function public.get_friends()
returns table (
  user_id uuid,
  display_name text,
  avatar_path text,
  city text,
  friend_since timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    other.id,
    other.display_name,
    case when ps.avatar_visibility = 'friends' then other.avatar_path end,
    case when ps.city_visibility = 'friends' then other.city end,
    f.responded_at
  from public.friendships f
  join public.profiles other
    on other.id = case when f.requester_id = auth.uid() then f.addressee_id else f.requester_id end
   and other.deleted_at is null
  join public.privacy_settings ps on ps.user_id = other.id
  where f.status = 'accepted'
    and (f.requester_id = auth.uid() or f.addressee_id = auth.uid())
    and not public.is_blocked(auth.uid(), other.id);
$$;

-- get_pending_requests: incoming pending requests with a minimal safe preview.
create or replace function public.get_pending_requests()
returns table (
  friendship_id uuid,
  user_id uuid,
  display_name text,
  avatar_path text,
  requested_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select f.id, requester.id, requester.display_name, requester.avatar_path, f.requested_at
  from public.friendships f
  join public.profiles requester on requester.id = f.requester_id and requester.deleted_at is null
  where f.addressee_id = auth.uid()
    and f.status = 'pending'
    and not public.is_blocked(auth.uid(), requester.id);
$$;

-- get_friend_profile: a friend's full profile, each field gated by its own visibility.
create or replace function public.get_friend_profile(p_friend uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_p public.profiles;
  v_ps public.privacy_settings;
  v_since timestamptz;
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;

  if not public.can_view_profile(v_uid, p_friend) then
    raise exception 'Profile not found' using errcode = 'P0002'; -- uniform, avoids enumeration
  end if;

  select * into v_p from public.profiles where id = p_friend and deleted_at is null;
  select * into v_ps from public.privacy_settings where user_id = p_friend;
  select responded_at into v_since from public.friendships
    where status = 'accepted'
      and user_low = least(v_uid, p_friend)
      and user_high = greatest(v_uid, p_friend)
    limit 1;

  return jsonb_build_object(
    'user_id', v_p.id,
    'display_name', v_p.display_name,
    'username', v_p.username,
    'bio', v_p.bio,
    'avatar_path', case when v_ps.avatar_visibility = 'friends' then v_p.avatar_path end,
    'city', case when v_ps.city_visibility = 'friends' then v_p.city end,
    'country_code', case when v_ps.city_visibility = 'friends' then v_p.country_code end,
    'friend_since', v_since
  );
end;
$$;

-- get_friend_leaderboard: self + accepted friends, with a period total OR a private marker.
-- The CLIENT computes the calendar-aware window (CheekyPintCore) and passes start/end plus
-- the period kind (which selects the relevant visibility switch). Blocked users never appear.
create or replace function public.get_friend_leaderboard(
  p_period_start timestamptz,
  p_period_end timestamptz,
  p_period_kind text,
  p_session_id uuid default null
)
returns table (
  user_id uuid,
  display_name text,
  avatar_path text,
  recorded_count int,
  is_private boolean,
  is_current_user boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;
  if p_period_kind not in ('session', 'week', 'month', 'year') then
    raise exception 'Invalid period kind %', p_period_kind using errcode = '22023';
  end if;
  if p_period_kind = 'session' and p_session_id is null then
    raise exception 'Session period requires a session id' using errcode = '22023';
  end if;

  return query
  with participants as (
    select v_uid as uid, true as is_me
    union
    select case when f.requester_id = v_uid then f.addressee_id else f.requester_id end, false
    from public.friendships f
    where f.status = 'accepted' and (f.requester_id = v_uid or f.addressee_id = v_uid)
  ),
  visible as (
    select p.uid, p.is_me, ps.avatar_visibility,
      p.is_me or (case p_period_kind
        when 'session' then ps.session_total_visibility
        when 'week' then ps.weekly_total_visibility
        when 'month' then ps.monthly_total_visibility
        when 'year' then ps.yearly_total_visibility
      end) = 'friends' as can_see_total
    from participants p
    join public.privacy_settings ps on ps.user_id = p.uid
    where p.is_me or not public.is_blocked(v_uid, p.uid)
  )
  select
    pr.id,
    pr.display_name,
    case when v.is_me or v.avatar_visibility = 'friends' then pr.avatar_path end,
    case when v.can_see_total then (
      select count(*)::int
      from public.pint_entries e
      where e.user_id = pr.id
        and e.deleted_at is null
        and e.alcohol_free = false
        and e.occurred_at >= p_period_start
        and e.occurred_at < p_period_end
        and (p_period_kind <> 'session' or e.session_id = p_session_id)
    ) else 0 end,
    not v.can_see_total,
    v.is_me
  from visible v
  join public.profiles pr on pr.id = v.uid and pr.deleted_at is null;
end;
$$;

-- get_favourite_pubs: up to five most-visited pubs for a user, honouring privacy.
create or replace function public.get_favourite_pubs(p_user uuid)
returns table (
  pub_id uuid,
  name text,
  city text,
  visit_count int,
  last_visit timestamptz,
  shared_visit_count int
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;

  if p_user <> v_uid then
    if public.is_blocked(v_uid, p_user)
       or not public.is_accepted_friend(v_uid, p_user)
       or coalesce((select favourite_pubs_visibility from public.privacy_settings where user_id = p_user), 'private') <> 'friends' then
      raise exception 'Not permitted' using errcode = 'P0002';
    end if;
  end if;

  return query
  select
    pb.id,
    pb.name,
    pb.city,
    count(*)::int as visits,
    max(e.occurred_at) as last_visit,
    (
      select count(distinct e2.session_id)::int
      from public.pint_entries e2
      where e2.pub_id = pb.id and e2.session_id is not null and e2.deleted_at is null
        and public.is_active_session_member(e2.session_id, v_uid)
        and public.is_active_session_member(e2.session_id, p_user)
    ) as shared_visits
  from public.pint_entries e
  join public.pubs pb on pb.id = e.pub_id
  left join public.user_pub_preferences up on up.user_id = p_user and up.pub_id = pb.id
  where e.user_id = p_user
    and e.deleted_at is null
    and e.pub_id is not null
    and coalesce(up.hidden_from_favourites, false) = false
  group by pb.id, pb.name, pb.city
  order by visits desc, last_visit desc
  limit 5;
end;
$$;

-- get_blocked_users: the users the caller has blocked, with names (self-only profile RLS
-- otherwise hides them). Used by the Blocked Users settings screen.
create or replace function public.get_blocked_users()
returns table (user_id uuid, display_name text, avatar_path text)
language sql
stable
security definer
set search_path = ''
as $$
  select p.id, p.display_name, p.avatar_path
  from public.blocks b
  join public.profiles p on p.id = b.blocked_id
  where b.blocker_id = auth.uid();
$$;
