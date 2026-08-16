-- Table-level grants for the RLS/RPC suite. **This file over-grants on purpose, and that is a
-- liability worth naming.**
--
-- The suite probes RPC-only tables directly (`select count(*) from public.nudges` must return 0
-- rows, not raise), which needs SELECT on tables the client is never granted. So the blanket
-- grant below stays.
--
-- What it also did, for as long as it existed, is hide the fact that the real database granted
-- `authenticated` nothing at all on `public` — newer Supabase Postgres images stopped handing out
-- DML on new tables in `public`, and the original comment here ("grants that Supabase normally
-- applies out of band") went stale without anyone noticing. The suite passed 114 checks against a
-- permission matrix the app could never see, while `select * from profiles` returned
-- `42501 permission denied for table profiles` in production. A live sign-in test found it.
--
-- The real grants now live in `20260816000100_client_table_grants.sql`, and
-- `client_grants_check.sql` runs against the migrations *before* this file loads, so the gap this
-- file can hide is checked separately rather than left to trust.
grant select, insert, update, delete on all tables in schema public to authenticated;
grant usage, select on all sequences in schema public to authenticated;
