-- Table-level grants, checked against the migrations alone.
--
-- Runs BEFORE `_shim_grants.sql`, which blanket-grants every table in `public` to `authenticated`
-- so the main suite can probe RPC-only tables directly. That blanket grant is also what hid a real
-- production outage for the whole life of this suite: the database granted `authenticated` no DML
-- on any table, so every direct-table read the Swift client makes came back
-- `42501 permission denied for table profiles` — including the profile read that decides whether a
-- signed-in user is onboarding or ready. Only the SECURITY DEFINER RPCs worked, because those run
-- as their owner and need no grant at all, which is exactly why an end-to-end check built on
-- `create_post` and `feed_page` passed against a database in which nothing was selectable.
--
-- So: the six tables the client reaches through PostgREST must be reachable off the migrations
-- alone, and the RPC-only ones must not be. Grants only — RLS still decides which *rows* come
-- back, and the main suite covers that.

set role authenticated;
-- Any uuid; RLS may legitimately return zero rows. A grant failure raises 42501 instead.
set local "app.uid" = '00000000-0000-4000-8000-0000000000a1';

do $$
declare
  t text;
  n int;
begin
  foreach t in array array[
    'profiles',            -- ProfileRepository.fetchMyProfile — the phase decision depends on it
    'privacy_settings',    -- ProfileRepository.fetchMyPrivacy
    'pint_entries',        -- DiaryRepository.entries
    'pubs',                -- PubsRepository search/persist
    'pub_sessions',        -- SessionsRepository.activeSession
    'session_members'
  ] loop
    begin
      execute format('select count(*) from public.%I', t) into n;
    exception when insufficient_privilege then
      raise exception 'FAIL grants: authenticated cannot select public.% — the Swift client '
                      'reads this table directly through PostgREST and will get 42501', t;
    end;
  end loop;
  raise notice 'PASS grants: every table the client reads directly is selectable by authenticated';
end $$;

do $$
declare
  t text;
  n int;
  leaked text[] := '{}';
begin
  -- These carry their own `revoke all on table ... from authenticated` and are reached only
  -- through RPCs. A blanket `grant ... on all tables` would silently undo that, which is the
  -- mistake this half of the check exists to catch.
  foreach t in array array['posts', 'post_cheers', 'post_comments', 'comment_mentions',
                           'nudges', 'storage_gc_queue'] loop
    begin
      execute format('select count(*) from public.%I', t) into n;
      leaked := leaked || t;
    exception when insufficient_privilege then
      null; -- expected
    end;
  end loop;
  if array_length(leaked, 1) is not null then
    raise exception 'FAIL grants: % is RPC-only but authenticated can select it directly',
                    array_to_string(leaked, ', ');
  end if;
  raise notice 'PASS grants: RPC-only tables stay unreadable by authenticated';
end $$;

reset role;
