# Privacy

CheekyPint is built to collect little and share less. This document describes what the app does;
the user-facing policy template is [legal/PRIVACY_POLICY.md](legal/PRIVACY_POLICY.md).

## Principles

- **Friends-only ceiling.** Every shareable *field* is friends-only-or-narrower and gated
  server-side, with **city and favourite pubs off by default**. The one exception: avatar and
  post-photo *bytes* sit in public-read storage buckets (unlisted, not access-controlled — see
  "Known tradeoff" below), so "nothing is ever public" is not quite true.
- **No precise location.** "City" is a broad, optional, user-typed area (e.g. "Graz, Austria").
  We never store a street address, and we never infer home from pub activity. Location is used
  only on demand for nearby-pub search (When-In-Use), never in the background.
- **Private diary.** Users can hide all quantities from friends and keep using the diary.
- **No ads, no cross-app tracking, no data sales.**

## What we collect

Account (auth id, email or Apple relay), profile (display name, optional username/bio/avatar/city),
diary (drinks with serving/time/optional pub/optional private note), feed content (post body,
optional post photo, optional place label, comments, @-mentions), social graph (friends, blocks,
reports), and minimal product analytics events. See
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
`delete-account` Edge Function completes storage (both the `avatars` and `post-images` buckets)
and auth-user removal. See
[legal/DATA_RETENTION_POLICY.md](legal/DATA_RETENTION_POLICY.md) and
[legal/ACCOUNT_DELETION_POLICY.md](legal/ACCOUNT_DELETION_POLICY.md).

## Known tradeoff

Avatars and post photos both live in public-read buckets (`avatars`, `post-images`) with
unguessable, per-user filenames; the paths are only returned to a client when the friends-only
visibility rules permit it, so the images are unlisted rather than strictly access-controlled —
anyone holding a URL (screenshot, forwarded link, scraped before a block) can fetch the bytes
directly, with no `Authorization` header, forever. A hardening pass can move both buckets to
signed URLs. Documented in [SECURITY.md](SECURITY.md) and, for post photos specifically, in
[MODERATION.md](MODERATION.md).

## Processors

Supabase (hosting, auth, database, storage). Apple (Sign in with Apple, push if added later).
Region and DPA details are placeholders pending the operator's configuration — see the policy
template.
