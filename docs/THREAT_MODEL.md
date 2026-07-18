# Threat model

Scope: the CheekyPint MVP (iOS client, Supabase backend). STRIDE, per asset. Mitigations link
to [SECURITY.md](SECURITY.md) and the tested policies/functions.

## Assets

- User identity + session tokens
- Private diary (pint entries, notes, pub visits)
- Social graph (friends, blocks, reports)
- Broad location (opt-in city) — **never** a precise address
- Friend / session tokens

## STRIDE

| Threat | Example | Mitigation | Residual |
|--------|---------|-----------|----------|
| **Spoofing** | Forge another user's requests | Supabase JWT on every request; `auth.uid()` server-side; Apple nonce | Depends on GoTrue/JWT integrity |
| **Tampering** | Insert entries as another user, fake timestamps | RLS self-only; RPC-only writes with server `created_at`; future-time rejection | — |
| **Repudiation** | Deny an action | `created_at`, `source`, audit columns; `flagged_high_frequency` metadata | Casual app — no strong non-repudiation |
| **Information disclosure** | Read a friend's raw entries / a stranger's profile / a blocked user | Definer RPCs with field-level privacy; block-first checks; "Private" placeholders | Pair-relationship probing via helpers (low) |
| **Denial of service** | Spam friend requests / token resolves / pints | `enforce_rate_limit` per action + window | Global DoS is Supabase infra's concern |
| **Elevation of privilege** | Call privileged SQL, bypass RLS | `search_path=''`, schema-qualified, `authenticated`-only grants; service role off-device | — |

## Abuse (non-security) cases

- **Underage use:** legal-age gate (not pre-checked, recorded) + 18+ default; report category
  `underage_concern`. Not identity verification (out of scope, invasive).
- **Fake totals:** self-reported by design; idempotency + rate limits + impossible-frequency
  flags reduce inflation; totals are clearly self-reported and never celebrated when clustered.
- **UGC (photos/text):** length limits + sanitisation, block/report/remove, admin disable,
  constrained social surface (no posts/DMs/feeds). See [MODERATION.md](MODERATION.md).

## Out of scope (MVP)

Device compromise / jailbreak, Supabase platform compromise, nation-state adversaries, payment
data (none collected).
