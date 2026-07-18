# Architecture

## Principles

1. **One source of truth for rules.** Counting, period math, privacy, leaderboard ranking,
   validation, QR tokens, and welfare/abuse logic live in the `CheekyPintCore` Swift package —
   Foundation-only, deterministic, and exhaustively unit-tested on macOS without Xcode.
2. **Defence in depth.** The backend re-enforces the same privacy/counting rules with Row Level
   Security and `SECURITY DEFINER` functions. The client never sees another user's raw rows.
3. **Thin, testable app.** SwiftUI views are dumb; `@Observable` view models orchestrate;
   repositories wrap the Supabase client and map to the tested core models.
4. **Minimal dependencies.** Native Apple frameworks + a hand-rolled Supabase REST/Auth client.
   No third-party iOS SPM packages in the MVP.

## Layers

```mermaid
flowchart TD
    subgraph iOS["iOS app (SwiftUI, iOS 17+)"]
      V[Views] --> VM[View models @Observable]
      VM --> R[Repositories]
      R --> SD[SupabaseData REST/RPC]
      R --> SA[SupabaseAuth actor]
      VM --> Core
      R --> Core
      SD --> Core["CheekyPintCore\n(counting · privacy · leaderboard · QR · validation · safety)"]
      SA --> KC[Keychain]
    end

    subgraph Supabase["Supabase"]
      PR[PostgREST] --> DB[(PostgreSQL + RLS)]
      RPC["SECURITY DEFINER RPCs\n(leaderboard · friend profile · token · pint · session)"] --> DB
      GT[GoTrue auth\nApple · Email OTP] --> DB
      ST[Storage: avatars] 
      EF[Edge Function: delete-account] --> DB
      EF --> ST
    end

    SD -->|"apikey + bearer JWT"| PR
    SD -->|rpc| RPC
    SA -->|token/verify/refresh| GT
    R -->|avatar upload| ST
    VM -->|account deletion| EF
```

The same domain package (`CheekyPintCore`) is used by the app to *compute* period windows and
*present* leaderboards, while the database *aggregates* using windows the client passes in — so
the tested calendar math is authoritative and never re-implemented in SQL.

## Module map (app)

- `App/` — `CheekyPintApp` (entry), `AppContainer` (composition root), `SessionController`
  (phase machine: loading → signedOut → onboarding → ready), `RootView`.
- `Core/Networking` — `AppConfig`, `SupabaseData` (PostgREST + RPC + storage), JSON coding, errors.
- `Core/Authentication` — `SupabaseAuth` (actor), `AuthSession`, `KeychainStore`.
- `Core/Database` — repositories + RPC contracts (Profile, Diary, Friends, Leaderboard, Pubs, Sessions).
- `Core/DesignSystem` — tokens (`Theme`), button styles, `RemoteAvatar`, `StatusView`.
- `Core/{Analytics,Location,QR,Utilities}` — services (privacy-preserving analytics, on-demand
  When-In-Use location, QR generate/scan, haptics, nonce, image resize).
- `Features/*` — one folder per feature, each with its views (+ view model where stateful).

## Screen map

```mermaid
flowchart LR
    Launch --> Welcome --> Responsible --> Age[Age confirmation] --> Auth
    Auth --> Setup[Profile setup] --> Privacy[Privacy setup] --> Home

    Home --> LogSheet[Log-a-pint sheet]
    Home --> MyQR[My QR]
    Home --> Board[Full leaderboard]
    Home --> Session[Active session]

    subgraph Tabs
      Home
      Friends --> Pending[Requests]
      Friends --> Add[Add friend: scan / manual]
      Add --> Preview[Friend preview] --> FriendProfile
      Friends --> FriendProfile[Friend profile] --> Report
      Pubs --> PubSearch --> PubDetail
      Pubs --> CreateSession
      Pubs --> JoinSession
      Profile --> History[My diary]
      Profile --> Settings
    end

    Settings --> EditProfile
    Settings --> PrivacySettings
    Settings --> Blocked[Blocked users]
    Settings --> Delete[Account deletion]
    Settings --> Legal[Legal & support]
```

## Key flows

- **Log a pint:** sheet generates a stable `IdempotencyKey` on open → `create_pint_entry` RPC
  (server timestamp, session-membership check, dedupe on `(user_id, idempotency_key)`) → local
  totals recomputed by `PersonalTotalsCalculator` → welfare tone chosen by `WelfareMonitor` →
  undo soft-deletes via `undo_recent_pint_entry`.
- **Add a friend:** `regenerate_friend_token` returns a raw token (cached in Keychain) rendered
  as `cheekypint://friend/<token>` → scanned/entered → `resolve_friend_token` returns a safe
  preview → `send_friend_request` → `respond_to_friend_request`.
- **Leaderboard:** client computes the `[start,end)` window with `PeriodCalculator` →
  `get_friend_leaderboard(start,end,kind,session)` returns per-friend totals or a private marker
  → `LeaderboardBuilder` ranks (competition ranking, current user always in preview).
