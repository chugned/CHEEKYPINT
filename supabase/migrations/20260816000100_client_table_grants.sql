-- CheekyPint schema — 10. Table-level grants for the client's direct-table access
--
-- Every table in `public` had RLS enabled and the right policies, and `authenticated` still could
-- not read a single row of any of them: no role in this database was ever granted table-level
-- SELECT/INSERT/UPDATE. PostgREST answers that with
--
--   403 {"code":"42501","message":"permission denied for table profiles",
--        "hint":"Grant the required privileges to the current role with: ..."}
--
-- before RLS is ever consulted, because grants are checked first.
--
-- Why nobody noticed. Newer Supabase Postgres images no longer hand `anon`/`authenticated` DML on
-- new tables in `public` — the default privileges for role `postgres` in this schema now read
-- `authenticated=Dxtm` (TRUNCATE/REFERENCES/TRIGGER only, no a/r/w/d). The RLS suite in
-- `supabase/tests` never saw it because `_shim_grants.sql` issues
-- `grant select, insert, update, delete on all tables in schema public to authenticated`
-- itself, under a comment describing those grants as something "Supabase normally applies out of
-- band". That was true once. It is not true of this database.
--
-- Only the RPC surface worked, because a SECURITY DEFINER function runs as its owner and needs no
-- grant on the tables it touches — which is exactly why an end-to-end check built on `create_post`
-- and `feed_page` passed against a database in which `select * from profiles` was forbidden.
--
-- Deliberately NOT `grant ... on all tables in schema public`. Six tables in this schema are
-- RPC-only on purpose and revoke themselves explicitly (`posts`, `post_cheers`, `post_comments`,
-- `comment_mentions`, `nudges`, `storage_gc_queue`); a blanket grant would re-open every one of
-- them, plus `blocks`, `friendships`, `friend_tokens`, `reports` and the clink tables, none of
-- which the client ever touches directly. Listed below are exactly the six tables the Swift
-- repositories reach through PostgREST, with exactly the verbs they use.
--
-- These grants widen nothing on their own: every table below has RLS enabled with a policy that
-- already constrains the same verb to the caller's own rows (`profiles_select_self`,
-- `privacy_update_self`, `pint_entries_select_self`, `pub_sessions_select_member`,
-- `session_members_select_comember`), except `pubs`, whose `pubs_select_all` is `true` by design —
-- pub records are shared reference data, and its INSERT policy still requires
-- `created_by = auth.uid()`.

-- ProfileRepository.fetchMyProfile / updateProfile / confirmLegalAge.
-- No INSERT: the only row insert is `handle_new_user()`, a SECURITY DEFINER trigger.
grant select, update on public.profiles to authenticated;

-- ProfileRepository.fetchMyPrivacy / updatePrivacy. Same reasoning on INSERT.
grant select, update on public.privacy_settings to authenticated;

-- DiaryRepository.entries. Writes go through `create_pint_entry` /
-- `undo_recent_pint_entry`, so no INSERT/UPDATE here — and the RLS suite asserts that a direct
-- insert into `pint_entries` is refused, which this keeps true.
grant select on public.pint_entries to authenticated;

-- PubsRepository.persist inserts a chosen pub with `created_by` set to the caller, then reads it
-- back via `Prefer: return=representation` — which needs SELECT as well as INSERT.
grant select, insert on public.pubs to authenticated;

-- SessionsRepository.activeSession and its membership lookup.
grant select on public.pub_sessions to authenticated;
grant select on public.session_members to authenticated;
