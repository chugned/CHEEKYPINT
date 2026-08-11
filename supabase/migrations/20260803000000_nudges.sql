-- CheekyPint: one-at-a-time, Facebook-Poke-style Nudges between accepted friends.
-- A Nudge is social only: it never changes pint totals or leaderboard rank.

create table public.nudges (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references public.profiles (id) on delete cascade,
  recipient_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  acknowledged_at timestamptz,
  constraint nudges_not_self check (sender_id <> recipient_id)
);

comment on table public.nudges is
  'One-at-a-time social Nudge between friends; never affects drink totals.';

-- Like a Facebook poke, the sender cannot stack another Nudge while one is unanswered.
create unique index nudges_one_unanswered_per_direction_idx
  on public.nudges (sender_id, recipient_id)
  where acknowledged_at is null;
create index nudges_recipient_unanswered_idx
  on public.nudges (recipient_id, created_at desc)
  where acknowledged_at is null;

-- No direct table access. Both reads and writes go through the friendship/block-aware RPCs.
alter table public.nudges enable row level security;
revoke all on table public.nudges from public, anon, authenticated;

create or replace function public.send_nudge(p_recipient_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;
  if p_recipient_id is null or p_recipient_id = v_uid
     or not public.is_accepted_friend(v_uid, p_recipient_id) then
    raise exception 'Friend not available' using errcode = 'P0002';
  end if;

  perform public.enforce_rate_limit('nudge_send', 30, interval '1 hour');

  if exists (
    select 1 from public.nudges c
    where c.sender_id = v_uid
      and c.recipient_id = p_recipient_id
      and c.acknowledged_at is null
  ) then
    -- If both friends happened to Nudge at the same instant, accepting the incoming one is
    -- still a valid "Nudge back"; the already-waiting outgoing row remains the reply.
    if exists (
      select 1 from public.nudges c
      where c.sender_id = p_recipient_id
        and c.recipient_id = v_uid
        and c.acknowledged_at is null
    ) then
      update public.nudges
         set acknowledged_at = now()
       where sender_id = p_recipient_id
         and recipient_id = v_uid
         and acknowledged_at is null;
      return;
    end if;

    raise exception 'Nudge already waiting'
      using errcode = 'P0001',
            hint = 'Nudge already sent — wait for your friend to nudge back.';
  end if;

  -- Sending back a Nudge acknowledges the unanswered one from this friend.
  update public.nudges
     set acknowledged_at = now()
   where sender_id = p_recipient_id
     and recipient_id = v_uid
     and acknowledged_at is null;

  insert into public.nudges (sender_id, recipient_id)
  values (v_uid, p_recipient_id);
end;
$$;

create or replace function public.get_received_nudges()
returns table (
  nudge_id uuid,
  sender_id uuid,
  display_name text,
  avatar_path text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select c.id,
         c.sender_id,
         p.display_name,
         case when ps.avatar_visibility = 'friends' then p.avatar_path end,
         c.created_at
    from public.nudges c
    join public.profiles p on p.id = c.sender_id and p.deleted_at is null
    join public.privacy_settings ps on ps.user_id = c.sender_id
   where c.recipient_id = auth.uid()
     and c.acknowledged_at is null
     and public.is_accepted_friend(auth.uid(), c.sender_id)
   order by c.created_at desc
   limit 30;
$$;

revoke all on function public.send_nudge(uuid) from public, anon;
revoke all on function public.get_received_nudges() from public, anon;
grant execute on function public.send_nudge(uuid) to authenticated;
grant execute on function public.get_received_nudges() to authenticated;
