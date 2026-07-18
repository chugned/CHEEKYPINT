# CheekyPint database tests

Two ways to verify the schema, RLS policies, and RPCs.

## 1. No Supabase / no Docker — throwaway local Postgres

`run_local_pg.sh` boots a temporary Postgres cluster, installs a tiny **auth/storage shim**
(so the real migrations run unmodified), applies **every migration + `seed.sql`**, then runs
the RLS/RPC allow-deny suite and tears everything down.

```bash
# Requires a local Postgres 16 (e.g. `brew install postgresql@16`).
cd supabase/tests
./run_local_pg.sh
# or point at a specific install:
PG_BIN=/usr/local/opt/postgresql@16/bin ./run_local_pg.sh
```

Every line should print `PASS`, ending with `ALL RLS/RPC CHECKS PASSED`.

### What the shim provides (`_shim_bootstrap.sql`)
- `extensions` schema with `pgcrypto` + `citext`
- Supabase roles: `anon`, `authenticated`, `service_role`
- `auth.users` + `auth.uid()` (reads the `app.uid` GUC so tests can "log in" as a user)
- `storage.buckets` / `storage.objects` + `storage.foldername()`

The suite (`rls_rpc_suite.sql`) simulates users with `set role authenticated` +
`set app.uid = '<uuid>'` and asserts, among other things:

| Area | Checks |
|------|--------|
| Isolation | a user reads only their own `pint_entries`; direct inserts are blocked |
| Block override | a blocked user cannot resolve tokens, view profiles, or appear on leaderboards; the block removed a pending request |
| Leaderboard | correct totals, alcohol-free excluded, hidden totals shown as **Private** |
| Idempotency | `create_pint_entry` with a repeated key returns the same row |
| Sessions | logging into a session you never joined is rejected |
| Tokens | resolve returns a safe preview; regenerating revokes the old token |
| Favourite pubs | respect `favourite_pubs_visibility` |

## 2. With the Supabase CLI

```bash
supabase start
supabase db reset          # applies migrations + seed.sql
# Run the same suite against the local stack's database:
psql "$(supabase status -o env | grep DB_URL | cut -d= -f2-)" -f supabase/tests/rls_rpc_suite.sql
```

> The suite is written as plain `plpgsql` assertions (portable) rather than pgTAP, so it runs
> anywhere `psql` can reach the database.
