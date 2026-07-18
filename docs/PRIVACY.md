# Privacy

CheekyPint is built to collect little and share less. This document describes what the app does;
the user-facing policy template is [legal/PRIVACY_POLICY.md](legal/PRIVACY_POLICY.md).

## Principles

- **Friends-only ceiling.** Nothing is ever public. Every shareable field has a switch, default
  friends-only, with **city and favourite pubs off by default**.
- **No precise location.** "City" is a broad, optional, user-typed area (e.g. "Graz, Austria").
  We never store a street address, and we never infer home from pub activity. Location is used
  only on demand for nearby-pub search (When-In-Use), never in the background.
- **Private diary.** Users can hide all quantities from friends and keep using the diary.
- **No ads, no cross-app tracking, no data sales.**

## What we collect

Account (auth id, email or Apple relay), profile (display name, optional username/bio/avatar/city),
diary (drinks with serving/time/optional pub/optional private note), social graph (friends,
blocks, reports), and minimal product analytics events. See
[APP_PRIVACY_DATA_MAPPING.md](APP_PRIVACY_DATA_MAPPING.md).

## Analytics

A single `AnalyticsService` protocol gates everything, shipping as a **no-op** by default. Only
the enumerated product events (`onboarding_completed`, `pint_saved`, …) may ever be sent. The
following are **never** sent to analytics: exact location, pub visit history, drink notes, friend
names, profile pictures, email addresses, friend QR payloads, or raw totals tied to an external
identity.

## User rights (GDPR)

Access, correction, deletion, portability, and consent withdrawal. Export and in-app account
deletion are available from Settings. Deletion anonymises + tears down app data immediately; the
`delete-account` Edge Function completes storage + auth-user removal. See
[legal/DATA_RETENTION_POLICY.md](legal/DATA_RETENTION_POLICY.md) and
[legal/ACCOUNT_DELETION_POLICY.md](legal/ACCOUNT_DELETION_POLICY.md).

## Known tradeoff

Avatars live in a public-read bucket with unguessable, per-user filenames; avatar paths are only
returned when visibility permits, so images are unlisted rather than strictly access-controlled.
A hardening pass can move to signed URLs. Documented in [SECURITY.md](SECURITY.md).

## Processors

Supabase (hosting, auth, database, storage). Apple (Sign in with Apple, push if added later).
Region and DPA details are placeholders pending the operator's configuration — see the policy
template.
