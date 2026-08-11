-- CheekyPint: one-at-a-time, Facebook-Poke-style Cheers between accepted friends.
-- A Cheers is social only: it never changes pint totals or leaderboard rank.

create table public.cheers (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references public.profiles (id) on delete cascade,
  recipient_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  acknowledged_at timestamptz,
  constraint cheers_not_self check (sender_id <> recipient_id)
);

comment on table public.cheers is
  'One-at-a-time social Cheers between friends; never affects drink totals.';

-- Like a Facebook poke, the sender cannot stack another Cheers while one is unanswered.
create unique index cheers_one_unanswered_per_direction_idx
  on public.cheers (sender_id, recipient_id)
  where acknowledged_at is null;
create index cheers_recipient_unanswered_idx
  on public.cheers (recipient_id, created_at desc)
  where acknowledged_at is null;

-- No direct table access. Both reads and writes go through the friendship/block-aware RPCs.
alter table public.cheers enable row level security;
revoke all on table public.cheers from public, anon, authenticated;

create or replace function public.send_cheers(p_recipient_id uuid)
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

  perform public.enforce_rate_limit('cheers_send', 30, interval '1 hour');

  if exists (
    select 1 from public.cheers c
    where c.sender_id = v_uid
      and c.recipient_id = p_recipient_id
      and c.acknowledged_at is null
  ) then
    -- If both friends happened to Cheers at the same instant, accepting the incoming one is
    -- still a valid "Cheers back"; the already-waiting outgoing row remains the reply.
    if exists (
      select 1 from public.cheers c
      where c.sender_id = p_recipient_id
        and c.recipient_id = v_uid
        and c.acknowledged_at is null
    ) then
      update public.cheers
         set acknowledged_at = now()
       where sender_id = p_recipient_id
         and recipient_id = v_uid
         and acknowledged_at is null;
      return;
    end if;

    raise exception 'Cheers already waiting'
      using errcode = 'P0001',
            hint = 'Cheers already sent — wait for your friend to cheer back.';
  end if;

  -- Sending back a Cheers acknowledges the unanswered one from this friend.
  update public.cheers
     set acknowledged_at = now()
   where sender_id = p_recipient_id
     and recipient_id = v_uid
     and acknowledged_at is null;

  insert into public.cheers (sender_id, recipient_id)
  values (v_uid, p_recipient_id);
end;
$$;

create or replace function public.get_received_cheers()
returns table (
  cheers_id uuid,
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
    from public.cheers c
    join public.profiles p on p.id = c.sender_id and p.deleted_at is null
    join public.privacy_settings ps on ps.user_id = c.sender_id
   where c.recipient_id = auth.uid()
     and c.acknowledged_at is null
     and public.is_accepted_friend(auth.uid(), c.sender_id)
   order by c.created_at desc
   limit 30;
$$;

revoke all on function public.send_cheers(uuid) from public, anon;
revoke all on function public.get_received_cheers() from public, anon;
grant execute on function public.send_cheers(uuid) to authenticated;
grant execute on function public.get_received_cheers() to authenticated;
