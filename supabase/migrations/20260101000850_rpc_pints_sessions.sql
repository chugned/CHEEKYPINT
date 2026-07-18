-- CheekyPint schema — 08b. RPCs: pint logging/undo, sessions, clinks, account deletion

-- create_pint_entry: the one true way to record a drink. Idempotent, rate-limited, server-
-- stamped, and session-membership-validated. Returns the stored row (existing one on retry).
create or replace function public.create_pint_entry(
  p_idempotency_key text,
  p_occurred_at timestamptz default now(),
  p_serving_type public.serving_type default 'pint',
  p_volume_ml double precision default null,
  p_alcohol_free boolean default false,
  p_pub_id uuid default null,
  p_session_id uuid default null,
  p_private_note text default null,
  p_source public.entry_source default 'manual'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.pint_entries;
  v_occurred timestamptz;
  v_recent int;
  v_last timestamptz;
  v_flagged boolean := false;
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;
  if p_idempotency_key is null or char_length(p_idempotency_key) = 0 then
    raise exception 'Missing idempotency key' using errcode = '22023';
  end if;

  -- Fast idempotent path: if this key already produced a row, return it unchanged.
  select * into v_row from public.pint_entries
    where user_id = v_uid and idempotency_key = p_idempotency_key;
  if found then
    return to_jsonb(v_row);
  end if;

  perform public.enforce_rate_limit('pint_create', 60, interval '1 hour');

  if p_serving_type = 'custom' and p_volume_ml is null then
    raise exception 'Custom serving requires a volume' using errcode = '22023';
  end if;

  -- Never trust a wildly future device clock; clamp small skews, reject large ones.
  v_occurred := coalesce(p_occurred_at, now());
  if v_occurred > now() + interval '5 minutes' then
    raise exception 'occurred_at is in the future' using errcode = '22023';
  end if;

  -- If attaching to a session, the caller must be a current member.
  if p_session_id is not null and not public.is_active_session_member(p_session_id, v_uid) then
    raise exception 'Not a member of that session' using errcode = '42501';
  end if;

  -- Non-punitive frequency flag (audit metadata only).
  select count(*), max(occurred_at) into v_recent, v_last
  from public.pint_entries
  where user_id = v_uid and deleted_at is null and occurred_at > now() - interval '1 hour';
  if v_recent >= 12 or (v_last is not null and v_occurred - v_last < interval '60 seconds') then
    v_flagged := true;
  end if;

  insert into public.pint_entries (
    user_id, pub_id, session_id, occurred_at, serving_type, volume_ml,
    alcohol_free, private_note, source, idempotency_key, flagged_high_frequency
  ) values (
    v_uid, p_pub_id, p_session_id, v_occurred, p_serving_type,
    case when p_serving_type = 'custom' then p_volume_ml else null end,
    coalesce(p_alcohol_free, false), nullif(left(coalesce(p_private_note, ''), 280), ''),
    coalesce(p_source, 'manual'), p_idempotency_key, v_flagged
  )
  on conflict (user_id, idempotency_key) do nothing
  returning * into v_row;

  -- Lost a race on the same key: return the row the other call inserted.
  if not found then
    select * into v_row from public.pint_entries
      where user_id = v_uid and idempotency_key = p_idempotency_key;
  end if;

  return to_jsonb(v_row);
end;
$$;

-- undo_recent_pint_entry: soft-delete one of the caller's own entries.
create or replace function public.undo_recent_pint_entry(p_entry_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.pint_entries;
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;
  update public.pint_entries
    set deleted_at = now()
    where id = p_entry_id and user_id = v_uid and deleted_at is null
    returning * into v_row;
  if not found then
    raise exception 'Entry not found' using errcode = 'P0002';
  end if;
  return to_jsonb(v_row);
end;
$$;

-- create_pub_session: start a session, join as host, return the RAW join token once.
create or replace function public.create_pub_session(p_pub_id uuid default null, p_name text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_raw text;
  v_session public.pub_sessions;
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;
  perform public.enforce_rate_limit('session_create', 20, interval '1 hour');

  v_raw := replace(replace(encode(extensions.gen_random_bytes(24), 'base64'), '+', '-'), '/', '_');
  v_raw := replace(v_raw, '=', '');

  insert into public.pub_sessions (pub_id, host_user_id, name, join_token_hash)
  values (p_pub_id, v_uid, nullif(left(coalesce(p_name, ''), 80), ''),
          encode(extensions.digest(v_raw, 'sha256'), 'hex'))
  returning * into v_session;

  insert into public.session_members (session_id, user_id, role)
  values (v_session.id, v_uid, 'host');

  return jsonb_build_object(
    'session_id', v_session.id,
    'join_token', v_raw,
    'started_at', v_session.started_at,
    'status', v_session.status
  );
end;
$$;

-- join_session_by_token: explicitly join an active session via its raw token.
create or replace function public.join_session_by_token(p_raw_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_session public.pub_sessions;
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;
  perform public.enforce_rate_limit('session_join', 30, interval '1 hour');

  select * into v_session from public.pub_sessions
    where join_token_hash = encode(extensions.digest(coalesce(p_raw_token, ''), 'sha256'), 'hex')
      and status = 'active';
  if not found then
    raise exception 'Session not found or ended' using errcode = 'P0002';
  end if;
  if public.is_blocked(v_uid, v_session.host_user_id) then
    raise exception 'Session not found or ended' using errcode = 'P0002';
  end if;

  insert into public.session_members (session_id, user_id, role)
  values (v_session.id, v_uid, 'member')
  on conflict (session_id, user_id) do update set left_at = null;

  return jsonb_build_object('session_id', v_session.id, 'status', v_session.status);
end;
$$;

create or replace function public.leave_session(p_session_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;
  update public.session_members set left_at = now()
    where session_id = p_session_id and user_id = v_uid and left_at is null;
end;
$$;

create or replace function public.end_session(p_session_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;
  update public.pub_sessions set status = 'ended', ended_at = now()
    where id = p_session_id and host_user_id = v_uid and status = 'active';
end;
$$;

-- create_clink: a decorative memory among session co-members. Never touches drink totals.
create or replace function public.create_clink(p_session_id uuid, p_participants uuid[])
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_clink public.clinks;
  v_participant uuid;
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;
  perform public.enforce_rate_limit('clink_create', 30, interval '1 hour');

  if not public.is_active_session_member(p_session_id, v_uid) then
    raise exception 'Not a member of that session' using errcode = '42501';
  end if;

  -- Every named participant must also be an active member and not blocked.
  foreach v_participant in array coalesce(p_participants, array[]::uuid[]) loop
    if v_participant = v_uid then continue; end if;
    if not public.is_active_session_member(p_session_id, v_participant)
       or public.is_blocked(v_uid, v_participant) then
      raise exception 'Participant is not in this session' using errcode = '42501';
    end if;
  end loop;

  insert into public.clinks (session_id, created_by) values (p_session_id, v_uid)
  returning * into v_clink;

  insert into public.clink_participants (clink_id, user_id, confirmed_at)
  values (v_clink.id, v_uid, now());

  foreach v_participant in array coalesce(p_participants, array[]::uuid[]) loop
    if v_participant = v_uid then continue; end if;
    insert into public.clink_participants (clink_id, user_id)
    values (v_clink.id, v_participant)
    on conflict do nothing;
  end loop;

  return jsonb_build_object('clink_id', v_clink.id);
end;
$$;

-- delete_account: in-app account deletion. Anonymises and tears down app data immediately.
-- The final auth-user deletion + storage cleanup is completed by the delete-account Edge
-- Function using the service role (see supabase/functions/delete-account).
create or replace function public.delete_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;

  -- Anonymise the profile and mark it deleted so it vanishes from every surface at once.
  update public.profiles set
    display_name = 'Deleted regular',
    username = null,
    bio = null,
    avatar_path = null,
    city = null,
    country_code = null,
    deleted_at = now()
  where id = v_uid;

  -- Tear down social graph + credentials.
  delete from public.friend_tokens where user_id = v_uid;
  delete from public.friendships where requester_id = v_uid or addressee_id = v_uid;
  delete from public.blocks where blocker_id = v_uid or blocked_id = v_uid;
  update public.session_members set left_at = now() where user_id = v_uid and left_at is null;

  -- Soft-delete the diary; hard removal happens when the auth user is deleted (cascade).
  update public.pint_entries set deleted_at = now() where user_id = v_uid and deleted_at is null;
end;
$$;
