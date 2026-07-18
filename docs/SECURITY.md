# Security

## Model

- **Trust boundary:** the iOS app is untrusted. It holds only the Supabase **anon** key and a
  per-user JWT. The **service-role** key exists only in Edge Function environments.
- **Authorization is server-side.** RLS + `SECURITY DEFINER` RPCs are the gatekeepers; the
  client's `VisibilityResolver` is a convenience mirror, not a control.

## Controls

| Risk | Control |
|------|---------|
| Reading others' raw data | `pint_entries`/`profiles` RLS = self only; cross-user reads via definer RPCs returning only permitted columns |
| Privacy bypass | Field visibility applied in `get_friend_profile` / `get_friend_leaderboard`; totals degrade to "Private", never a fake zero |
| Blocked-user leakage | `is_blocked(a,b)` checked first in every RPC/policy; block tears down friendships and pending requests |
| Duplicate / replayed writes | `create_pint_entry` idempotency key + unique constraint; Sign in with Apple nonce |
| Abuse / spam | `enforce_rate_limit` on token resolve/regenerate, friend requests, session joins, pint creation, reports, clinks |
| Token theft via QR | QR carries only an opaque 256-bit token; server stores only its SHA-256 hash; tokens are revocable + regenerable |
| Enumeration | Uniform "not valid / not found" errors on token resolve and friend-profile; no sequential IDs; usernames validated but lookups are rate-limited |
| Privilege escalation via functions | All definer functions `set search_path = ''`, schema-qualify everything, and are granted to `authenticated` only; internal helpers revoked |
| Secret leakage | Service-role key never in client; `.env` and `Secrets.xcconfig` git-ignored; anon key is non-secret by design |
| Session/credential theft on device | Session tokens in Keychain (`AfterFirstUnlock`, no iCloud sync); no tokens in QR payloads |

## Notable decisions & residual risks

- **Helper predicates (`is_blocked`, `is_accepted_friend`, …)** are `EXECUTE`-able by
  `authenticated` because RLS policies call them. This permits probing whether *arbitrary* pairs
  are friends/blocked — a low-severity information leak accepted for the MVP. Hardening: add a
  `where auth.uid() in (a,b)` guard.
- **Avatar bucket is public-read** with unguessable, `<uid>/`-scoped filenames; avatar *paths*
  are only returned when visibility permits, so images are effectively unlisted. Hardening: a
  private bucket served via short-lived signed URLs minted after RPC authorization.
- **JWT `sub` is read unverified** on the client only to learn the local user id after a magic
  link; it is never used for authorization (the server verifies every request).

## Testing

`supabase/tests/rls_rpc_suite.sql` asserts both allowed and denied paths (stranger can't read a
private profile; friend gets aggregates but not raw entries; blocked user disappears; revoked
token can't resolve; can't edit another user's row; can't join a session you weren't invited to).
Run via `supabase/tests/run_local_pg.sh`. See also [THREAT_MODEL.md](THREAT_MODEL.md).
