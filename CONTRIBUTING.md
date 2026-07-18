# Contributing

## Ground rules

- **Rules live in `CheekyPintCore`.** Any counting, period, privacy, leaderboard, validation, or
  safety behaviour goes in the tested package — never re-implemented in a view model, repository,
  or SQL. Add/adjust tests in `CheekyPintCoreTests` (and `corecheck`) alongside changes.
- **The server is the gatekeeper.** New cross-user reads/writes go through a `SECURITY DEFINER`
  RPC with rate limiting where appropriate; RLS stays own-rows-only. Add allow/deny cases to
  `supabase/tests/rls_rpc_suite.sql`.
- **Safety is non-negotiable.** Nothing may reward, pressure, or celebrate heavy/rapid drinking
  (see [docs/RESPONSIBLE_DRINKING.md](docs/RESPONSIBLE_DRINKING.md)). No global leaderboards.
- **Privacy by default.** New fields default to friends-only (or off); never add public
  visibility; never put personal data in QR payloads or analytics.

## Workflow

1. Branch from `main`.
2. If you changed the app's file structure, run `xcodegen generate` and commit the updated
   `CheekyPint.xcodeproj`.
3. Green gates before PR:
   - `cd CheekyPintCore && swift run corecheck`
   - `supabase/tests/run_local_pg.sh`
   - App tests in Xcode (`⌘U`) if you touched app code.
4. Keep migrations **append-only** and idempotent-friendly; never edit a released migration.

## Style

- Swift 6 language mode, strict concurrency. Value types + `Sendable`; `actor`/`@MainActor` for
  shared mutable state. Match the surrounding code's naming and comment density.
- SwiftUI: dumb views, `@Observable` view models, repositories for I/O. Use `Theme` tokens — no
  hard-coded colours/spacing. Every screen needs loading/empty/offline/error states and VoiceOver
  labels.
- SQL: schema-qualify inside `SECURITY DEFINER` functions and `set search_path = ''`.

## Commit / PR

Small, focused commits. Describe the user-facing change and which gate proves it. Never commit
secrets — `.env`, `Secrets.xcconfig`, and service-role keys are git-ignored.
