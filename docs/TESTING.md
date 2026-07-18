# Testing

Three independently runnable layers.

## 1. Domain core — `CheekyPintCore`

The riskiest logic (counting, period math, privacy, leaderboard, validation, QR, safety) is
Foundation-only and fully unit-tested.

```bash
cd CheekyPintCore
swift run corecheck   # 56 assertions, no Xcode required
swift test            # full XCTest suite (Xcode or a swift.org toolchain that bundles XCTest)
```

Covers (master prompt §24 unit tests): week/month/year boundaries, locale first-weekday,
time-zone reclassification, DST transitions, leap years, session windows; alcohol-free exclusion,
soft-delete, idempotency, serving-size mapping, standard servings; leaderboard ranking/ties/private
rows/current-user preview; block-overrides-everything + placeholders + pending previews; username
validation; text sanitisation (control/zero-width/bidi, grapheme-safe truncation); token format +
uniqueness + deep-link round-trips; welfare tone + abuse cadence.

> The Command Line Tools toolchain here lacks `XCTest`/`Testing`, so `corecheck` is the local
> gate; the XCTest suite runs in Xcode/CI.

## 2. Backend — RLS + RPC allow/deny

```bash
cd supabase/tests && ./run_local_pg.sh      # throwaway Postgres + auth/storage shim
# or, with the Supabase CLI:
supabase db reset && psql "$DB_URL" -f supabase/tests/rls_rpc_suite.sql
```

Covers (master prompt §24 integration + RLS): isolation (own entries only, direct insert blocked),
block override (token/profile/leaderboard/pending-request), leaderboard totals + alcohol-free +
"Private", idempotent create, session-membership enforcement, undo soft-delete, token resolve +
revocation, favourite-pub privacy, can't-edit-others.

## 3. App — XCTest / XCUITest

In Xcode: `⌘U` on the **CheekyPint** scheme.

- `CheekyPintTests` — app-target smoke tests (core linkage, deep-link round-trip, privacy defaults).
- `CheekyPintUITests` — onboarding (age gate not pre-checked); extend with log/undo, add-friend,
  privacy, and delete-account flows.

Recommended CI: run (1) and (2) on every PR (no Xcode needed for the domain smoke via `corecheck`,
Postgres for the backend), and (3) on macOS runners with Xcode 16.

## Fixtures

`supabase/seed.sql` provides deterministic users (Alice/Barnaby/Ceri/Dev), an active session,
pubs, friendships (incl. a block that removed a pending request), and sample entries — reused by
the RLS suite and handy for manual QA.
