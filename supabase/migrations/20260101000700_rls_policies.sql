-- CheekyPint schema — 07. Row Level Security
--
-- Philosophy: DIRECT table access is locked down to the caller's OWN rows. Every cross-user
-- read (friend profile, leaderboard totals, previews, favourite pubs, session co-members)
-- goes through a SECURITY DEFINER RPC in migration 08, which applies field-level privacy and
-- block rules and returns only the exact columns permitted. This makes a column-level leak
-- through RLS structurally impossible: if you can read a profiles row at all, it is your own.

-- One more helper, needed by session/clink policies.
create or replace function public.is_active_session_member(p_session uuid, p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.session_members m
    where m.session_id = p_session and m.user_id = p_user and m.left_at is null
  );
$$;

-- profiles ------------------------------------------------------------------------------
alter table public.profiles enable row level security;

create policy profiles_select_self on public.profiles
  for select to authenticated
  using (id = auth.uid());

create policy profiles_insert_self on public.profiles
  for insert to authenticated
  with check (id = auth.uid());

create policy profiles_update_self on public.profiles
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- privacy_settings ----------------------------------------------------------------------
alter table public.privacy_settings enable row level security;

create policy privacy_select_self on public.privacy_settings
  for select to authenticated using (user_id = auth.uid());
create policy privacy_insert_self on public.privacy_settings
  for insert to authenticated with check (user_id = auth.uid());
create policy privacy_update_self on public.privacy_settings
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- friend_tokens -------------------------------------------------------------------------
-- Readable by owner (to list/label active codes). All writes happen through RPCs.
alter table public.friend_tokens enable row level security;

create policy friend_tokens_select_self on public.friend_tokens
  for select to authenticated using (user_id = auth.uid());

-- friendships ---------------------------------------------------------------------------
-- Visible when you are a party to the edge. Writes go through RPCs (send/respond/remove).
alter table public.friendships enable row level security;

create policy friendships_select_involved on public.friendships
  for select to authenticated
  using (requester_id = auth.uid() or addressee_id = auth.uid());

-- blocks --------------------------------------------------------------------------------
-- You can see who YOU blocked (not who blocked you). Writes via RPC.
alter table public.blocks enable row level security;

create policy blocks_select_own on public.blocks
  for select to authenticated using (blocker_id = auth.uid());

-- reports -------------------------------------------------------------------------------
alter table public.reports enable row level security;

create policy reports_select_own on public.reports
  for select to authenticated using (reporter_id = auth.uid());

-- pubs ----------------------------------------------------------------------------------
-- Public business data: any authenticated user may read. Users may suggest new pubs and
-- edit ones they created.
alter table public.pubs enable row level security;

create policy pubs_select_all on public.pubs
  for select to authenticated using (true);
create policy pubs_insert_authenticated on public.pubs
  for insert to authenticated with check (created_by = auth.uid());
create policy pubs_update_creator on public.pubs
  for update to authenticated using (created_by = auth.uid()) with check (created_by = auth.uid());

-- pub_sessions --------------------------------------------------------------------------
-- Visible to the host and current/past members. Writes via RPC.
alter table public.pub_sessions enable row level security;

create policy pub_sessions_select_member on public.pub_sessions
  for select to authenticated
  using (
    host_user_id = auth.uid()
    or exists (
      select 1 from public.session_members m
      where m.session_id = id and m.user_id = auth.uid()
    )
  );

-- session_members -----------------------------------------------------------------------
-- Members of a session can see each other; you can always see your own membership rows.
alter table public.session_members enable row level security;

create policy session_members_select_comember on public.session_members
  for select to authenticated
  using (user_id = auth.uid() or public.is_active_session_member(session_id, auth.uid()));

-- clinks --------------------------------------------------------------------------------
alter table public.clinks enable row level security;

create policy clinks_select_session on public.clinks
  for select to authenticated
  using (public.is_active_session_member(session_id, auth.uid()));

alter table public.clink_participants enable row level security;

create policy clink_participants_select on public.clink_participants
  for select to authenticated
  using (
    user_id = auth.uid()
    or exists (
      select 1 from public.clinks c
      where c.id = clink_id and public.is_active_session_member(c.session_id, auth.uid())
    )
  );

-- pint_entries --------------------------------------------------------------------------
-- The strictest table: you can ONLY ever read your own entries. Friends' raw entries are
-- never exposed; only aggregates via get_friend_leaderboard. Writes via RPC (create/undo).
alter table public.pint_entries enable row level security;

create policy pint_entries_select_self on public.pint_entries
  for select to authenticated using (user_id = auth.uid());

-- user_pub_preferences ------------------------------------------------------------------
alter table public.user_pub_preferences enable row level security;

create policy user_pub_prefs_all_self on public.user_pub_preferences
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- rate_limit_events ---------------------------------------------------------------------
-- No policies: enabling RLS with none denies all direct access. Only SECURITY DEFINER
-- functions (enforce_rate_limit) touch this table.
alter table public.rate_limit_events enable row level security;
