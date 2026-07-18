# Implementation plan

## Milestones & status

| # | Milestone | Status |
|---|-----------|--------|
| 1 | **Domain core** — models, counting, privacy, leaderboard, validation, QR, safety + tests | ✅ Done & verified (`swift run corecheck`: 56/56) |
| 2 | **Backend** — migrations, RLS, RPCs, seed, Edge Function, tests | ✅ Done & verified (13 migrations + 20/20 RLS/RPC checks on Postgres 16) |
| 3 | **App shell** — Xcode project, design system, config, services (auth/data/keychain/analytics/location/QR), repositories | ✅ Done (project generates; 57 files parse clean) |
| 4 | **Features** — onboarding, home + log/undo, QR/friends, leaderboard, profiles, pubs/sessions, settings, moderation, deletion; all 29 screens | ✅ Done (structure complete; requires Xcode to build/run) |
| 5 | **Docs, legal, App Store, release** | ✅ Done (this milestone) |
| — | **Hardening** — see "Remaining" below | ◻︎ Fast-follow |

## Vertical slice (Phase 4 priority — implemented)

Create account → confirm age → set profile → **log a pint → undo → see totals** → generate QR →
add a friend → see standings. End-to-end wired across core + backend + app.

## File map (created)

- `CheekyPintCore/Sources/CheekyPintCore/**` — Models, Counting, Serving, Leaderboard, Privacy,
  Validation, QR, Utilities (+ `Tests` and `corecheck`).
- `supabase/migrations/2026010100*.sql` (extensions/enums → tables → helpers → triggers → RLS →
  RPCs → grants → storage), `seed.sql`, `functions/delete-account`, `tests/`.
- `CheekyPint/App`, `CheekyPint/Core/{Networking,Authentication,Database,DesignSystem,Analytics,
  Location,QR,Utilities}`, `CheekyPint/Features/*`, `CheekyPint/Resources/*`.
- `docs/**`, `docs/legal/**`, `README`, `CONTRIBUTING`, `THIRD_PARTY_NOTICES`, `.env.example`,
  `project.yml`, `CheekyPint.xcodeproj`.

## Database changes

All schema is new (greenfield). Migrations are append-only; never edit a released one. Adding a
cross-user read = a new `SECURITY DEFINER` RPC + an allow/deny test.

## Dependencies

iOS: Apple frameworks only (no third-party SPM). Backend: Supabase + Postgres extensions. Tooling:
XcodeGen (project), Postgres 16 (local backend tests).

## Test strategy

Domain via XCTest/`corecheck` (no Xcode needed for the smoke); backend via a plpgsql allow/deny
suite on a throwaway Postgres; app via XCTest/XCUITest in Xcode. See [docs/TESTING.md](docs/TESTING.md).

## Resolved decisions (independent, per prompt §33)

- Native URLSession Supabase client instead of a third-party SDK (dependency minimisation).
- Manual friend code = the raw opaque token (paste/scan). A short human-typeable code
  (`ShortFriendCode` exists in core) needs a backend column — deferred.
- Onboarding age gate is collected pre-auth and persisted immediately after sign-in.
- Xcode project committed **and** regeneratable via XcodeGen.

## Remaining / unresolved (needs owner input or a hardening pass)

- Build/run the app in Xcode 16 and fix any type-level issues (no iOS SDK available in this
  environment — only the domain core and backend were executable here).
- Sign in with Apple + associated-domains require a real Apple Developer team + hosted AASA.
- Short friend-code path (backend column + resolver) if desired.
- Avatar hardening (signed URLs) and helper-predicate probing guard (see [docs/SECURITY.md](docs/SECURITY.md)).
- Realtime session presence (optional), richer clink UI, data-export implementation.
- Legal templates require professional review before production.
