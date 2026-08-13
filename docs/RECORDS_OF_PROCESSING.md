# Records of Processing Activities (DSGVO / GDPR Art. 30)

> **Status: operator-completable draft, not reviewed by a qualified professional.** Every
> `[[double-bracketed]]` value depends on a decision the operator has not yet made and must be
> filled in before this record is relied on. This follows the placeholder convention already used
> in `docs/legal/`. Nothing here is legal advice.
>
> **Method.** Every statement about what the system enforces cites the shipped code that enforces
> it, as `file:line`, in the style of [MODERATION.md](MODERATION.md). Where a document elsewhere in
> this repository disagrees with the code, the code is authoritative and the disagreement is listed
> in [§9](#9-accuracy-notes-and-known-gaps). Claims that could not be grounded in code are marked
> as unenforced rather than restated as fact.
>
> **Unresolved classification.** Whether the drink diary constitutes special-category health data
> under Art. 9 is open and materially changes this record (see [§2.1](#21-the-unresolved-art-9-question)
> and [DPIA.md](DPIA.md) §3.1). The Art. 9 row in [§4](#4-categories-of-personal-data) is
> deliberately left unresolved.

---

## 1. Controller and contacts (Art. 30(1)(a))

| Field | Value |
|-------|-------|
| Controller (legal entity) | `[[Operator legal entity]]` |
| Registered address | `[[registered address, Austria/EU]]` |
| Representative (if controller is outside the EU) | `[[not applicable / name + address]]` |
| Data protection officer | `[[to be appointed if required — Art. 37 assessment not yet performed]]` |
| Privacy contact | `[[privacy@cheekypint.app]]` |
| Joint controllers | `[[none identified]]` |
| Supervisory authority | Austrian Datenschutzbehörde (assumed from `[[main establishment]]`; confirm once the entity is registered) |

The app ships a support address of `support@cheekypint.app`, marked in-repo as a placeholder
(`docs/MODERATION.md:164`).

## 2. Purposes of processing (Art. 30(1)(b))

| # | Purpose | Processing operations | Stated legal basis |
|---|---------|----------------------|--------------------|
| P1 | Account creation and authentication | Sign in with Apple or email magic link / OTP; one `profiles` + `privacy_settings` row created per auth user by trigger (`supabase/migrations/20260101000650_auth_bootstrap.sql:8-32`) | Contract, per `docs/legal/PRIVACY_POLICY.md:34` |
| P2 | Operating the personal drink diary | `create_pint_entry`, `undo_recent_pint_entry` (`supabase/migrations/20260101000850_rpc_pints_sessions.sql:5-109`) | Contract |
| P3 | Sharing selected fields and totals with accepted friends | `get_friends`, `get_friend_profile`, `get_friend_leaderboard`, `get_favourite_pubs` (`supabase/migrations/20260101000800_rpc_social.sql:231-448`) | Contract |
| P4 | Friends-only social feed (posts, photos, reactions, comments, @-mentions) | `create_post`, `feed_page`, `delete_post` (`supabase/migrations/20260811000500_rpc_feed_posts.sql`), `toggle_post_cheers`, `add_comment`, `delete_comment`, `post_comments_page` (`supabase/migrations/20260811000600_rpc_feed_social.sql`). **Backend only — no client surface ships yet** (see §9.11) | Contract |
| P5 | Pub selection and shared pub sessions | `create_pub_session`, `join_session_by_token`, `leave_session`, `end_session`, `create_clink` (`supabase/migrations/20260101000850_rpc_pints_sessions.sql:112-249`) | Contract |
| P6 | Social gestures (Nudges) | `send_nudge`, `get_received_nudges` (`supabase/migrations/20260803000000_nudges.sql:28-112`) | Contract |
| P7 | Safety and moderation | `report_user` (`supabase/migrations/20260101000800_rpc_social.sql:204-228`), `report_post` / `report_comment` (`supabase/migrations/20260811000700_rpc_feed_reports.sql:4-76`), block/unblock (`…000800:167-201`), administrative profile disable via `profiles.deleted_at` (`docs/MODERATION.md:155-163`) | Legitimate interests, per `docs/legal/PRIVACY_POLICY.md:35` |
| P8 | Abuse prevention and service integrity | `enforce_rate_limit` writes one `rate_limit_events` row per protected call (`supabase/migrations/20260101000600_security_helpers.sql:100-127`) | Legitimate interests |
| P9 | Age assurance for an alcohol-related service | `profiles.legal_age_confirmed_at`, a **self-declared** timestamp (`supabase/migrations/20260101000200_core_tables.sql:20,29`) set by a direct client update (`CheekyPint/Core/Database/ProfileRepository.swift:80-83`). No verification of any kind is performed | Contract / legal obligation, per `docs/legal/PRIVACY_POLICY.md:39-40` |
| P10 | Responding to data-subject access and portability requests | `export_my_data()` (`supabase/migrations/20260812000500_export_my_data.sql:81-403`). **No client entry point ships yet** (see §9.1) | Legal obligation (Art. 15, 20) |
| P11 | Account deletion | `delete_account()` (`supabase/migrations/20260101000850_rpc_pints_sessions.sql:254-284`) completed by the `delete-account` Edge Function (`supabase/functions/delete-account/index.ts:37-72`), invoked by the app (`CheekyPint/Core/Database/ProfileRepository.swift:98-101`) | Legal obligation (Art. 17) |
| P12 | Product analytics | `AnalyticsService` ships as a no-op; only nine enumerated event names exist and none carries personal data (`CheekyPint/Core/Analytics/AnalyticsService.swift:6-29`). No event sink is wired up | Consent where required, per `docs/legal/PRIVACY_POLICY.md:36` — currently moot, as nothing is sent |

Legal bases above are transcribed from the unreviewed policy template, not independently
established. `docs/legal/PRIVACY_POLICY.md` is itself marked as requiring professional review
(`docs/legal/PRIVACY_POLICY.md:3-4`).

### 2.1 The unresolved Art. 9 question

P2 records, per named and authenticated user, how much alcohol they consumed, when, and where,
indefinitely and cumulatively: `pint_entries.occurred_at`, `serving_type`, `volume_ml`,
`alcohol_free`, `pub_id` (`supabase/migrations/20260101000500_pint_and_clink_tables.sql:7-30`),
plus a server-computed drinking-pace flag `flagged_high_frequency`
(`supabase/migrations/20260101000850_rpc_pints_sessions.sql:59-64`).

Whether that data set is "data concerning health" within Art. 4(15) and therefore a special
category under Art. 9(1) is **unresolved**. It is not resolved in this document, and it must not be
assumed either way from the fact that this record was completed. What turns on the answer:

- whether Art. 6 alone suffices or Art. 9(2) — in practice explicit consent under Art. 9(2)(a) —
  is additionally required for the diary at all;
- whether the current contract basis for P2 is valid;
- whether a DPIA is mandatory rather than prudent (Art. 35(3)(b));
- whether `docs/legal/PRIVACY_POLICY.md:28`'s statement that no health data is collected, and
  `docs/APP_PRIVACY_DATA_MAPPING.md:31`'s listing of health data as "not collected", are accurate.

This requires qualified Austrian legal advice. See [DPIA.md](DPIA.md) §3.1.

## 3. Categories of data subjects (Art. 30(1)(c))

| Category | How they enter the system | Notes |
|----------|---------------------------|-------|
| **Registered adult users** who have self-declared they meet their local legal drinking age | Sign-up creates `auth.users` → `profiles` + `privacy_settings` (`supabase/migrations/20260101000650_auth_bootstrap.sql:15-24`) | The declaration is a self-set timestamp with no verification (`CheekyPint/Core/Database/ProfileRepository.swift:80-83`). A user who is in fact under age is therefore a foreseeable data subject, and `report_category` includes `underage_concern` for exactly that case (`supabase/migrations/20260101000100_extensions_and_enums.sql:32`) |
| **Users referenced in another user's data** | As `friendships.requester_id`/`addressee_id`, `blocks.blocked_id`, `comment_mentions.mentioned_user_id`, `nudges.recipient_id`, `session_members.user_id`, `clink_participants.user_id`, `reports.reported_user_id` | These identifiers appear inside another user's records and, for `blocks` and `reports`, are created without the referenced person's knowledge |
| **Reported users** | `reports.reported_user_id` (required when a report is filed; de-linked to NULL if that account is later deleted) and `reports.reported_user_key`, a pseudonym for the subject that survives deletion (`supabase/migrations/20260101000300_social_tables.sql`) | Accompanied by up to 1,000 characters of free text written by the reporter. A report about a person is retained after that person erases their account — see §4.10 and §7 |
| **Non-users depicted in photographs** | Uploaded avatar or post-photo bytes; bystanders in a pub photo. Nothing in the schema records them and no consent mechanism exists | The only categories of data subject for whom the system provides **no** rights mechanism at all — they cannot be identified, notified, or served an access or erasure request. See [DPIA.md](DPIA.md) §3.2 |
| **Pub-suggestion authors** | `pubs.created_by` (`supabase/migrations/20260101000400_pub_tables.sql:18`) | Retained after account deletion as `null` (`on delete set null`), i.e. de-linked rather than deleted |
| **Deleted-account users** | `profiles.deleted_at` set and identifying fields nulled (`supabase/migrations/20260101000850_rpc_pints_sessions.sql:265-273`) | Residues in `storage_gc_queue.object_path` (§4.11) and in backups |

Children are out of scope by policy (`docs/legal/PRIVACY_POLICY.md:74-75`) but not by any technical
control.

## 4. Categories of personal data (Art. 30(1)(c))

Enumerated from the schema, column by column. "Client-readable" means the `authenticated` role can
read the row directly under RLS; "definer-only" means all privileges are revoked and access is
possible only through a `security definer` RPC.

### 4.1 Authentication data — `auth.users` (Supabase-managed)

Auth identifier (uuid), email address **or** Apple private-relay email, plus Supabase's own auth
metadata and logs (`[[and a password credential, if password sign-in is enabled on the hosted
project — the app itself uses only Sign in with Apple and email magic link / OTP,
CheekyPint/Core/Authentication/SupabaseAuth.swift:5,43-48]]`). Configured at
`supabase/config.toml:24-40`. Not in this repository's migrations; the app only ever holds the anon
key and a per-user JWT (`docs/SECURITY.md:5-6`), and session tokens are kept in the Keychain with
`kSecAttrAccessibleAfterFirstUnlock` (`CheekyPint/Core/Authentication/KeychainStore.swift:24`).

Note: a new user's initial `display_name` is derived from the local part of their email address
(`supabase/migrations/20260101000650_auth_bootstrap.sql:15-19`), so an email fragment can persist in
a profile field until the user changes it.

### 4.2 Profile data — `public.profiles` (`supabase/migrations/20260101000200_core_tables.sql:6-26`)

`id` (= auth uuid), `display_name` (1–40 chars), `username` (citext, unique, `^[a-z][a-z0-9_]{2,19}$`),
`bio` (≤160), `avatar_path` (storage key), `city` (≤60, user-typed, broad), `country_code` (ISO-2),
`legal_age_confirmed_at`, `timezone`, `locale`, `created_at`, `updated_at`, `deleted_at`.
Client-readable **and client-writable** for the owner only
(`supabase/migrations/20260101000700_rls_policies.sql:26-37`).

### 4.3 Privacy preferences — `public.privacy_settings` (`…000200_core_tables.sql:40-53`)

`user_id` plus nine visibility switches — `profile_visibility`, `avatar_visibility`,
`city_visibility`, `session_total_visibility`, `weekly_total_visibility`, `monthly_total_visibility`,
`yearly_total_visibility`, `favourite_pubs_visibility`, `shared_sessions_visibility` — each
`private` or `friends`; there is no `public` value (`…000100_extensions_and_enums.sql:10-12`).
Plus `created_at`, `updated_at`. Self-only (`…000700_rls_policies.sql:42-47`).

### 4.4 Friend-invite credentials — `public.friend_tokens` (`…000200_core_tables.sql:64-71`)

`id`, `user_id`, `token_hash` (SHA-256 hex only — the raw token is returned once and never stored,
`…000800_rpc_social.sql:27-31`), `expires_at`, `revoked_at`, `created_at`. Owner-readable
(`…000700_rls_policies.sql:53-54`). Deliberately excluded from the data export
(`…20260812000500_export_my_data.sql:63-68`).

### 4.5 Drink diary — `public.pint_entries` (`…000500_pint_and_clink_tables.sql:7-30`)

`id`, `user_id`, `pub_id`, `session_id`, `occurred_at` (user-adjustable), `serving_type`
(`half_pint`/`pint`/`ml_330`/`ml_500`/`custom`), `volume_ml` (0–5000), `alcohol_free`,
`private_note` (≤280 chars of free text), `source` (`manual`/`quick_log`/`offline_queue`),
**`idempotency_key`** (client-generated string, unique per user — `…000500:34`),
**`flagged_high_frequency`** (server-computed behavioural inference: set when the user logged ≥12
entries in the trailing hour or logged within 60 seconds of their previous entry —
`…000850_rpc_pints_sessions.sql:59-64`; described in-schema as non-punitive audit metadata,
`…000500:23-24`), `created_at` (server-authoritative), `updated_at`, `deleted_at`.
Readable by the owner only (`…000700_rls_policies.sql:135-136`); friends only ever see counts via
`get_friend_leaderboard` (`…000800_rpc_social.sql:379-388`).

`flagged_high_frequency` is exported to the data subject (`…000500_export_my_data.sql:166`) but is
never surfaced in the app UI.

### 4.6 Venue and location data

- `public.pubs` (`…000400_pub_tables.sql:6-21`): `id`, `external_source` (`mapkit`/`user_suggested`),
  `external_identifier`, `name` (1–120), `formatted_address` (**no length cap**), `city`,
  `country_code`, `latitude`, `longitude`, `created_by`, `created_at`, `updated_at`. Business data,
  readable by every authenticated user (`…000700_rls_policies.sql:82-83`) and insertable by any
  authenticated user with `created_by = auth.uid()` (`…000700:84-85`) — direct DML with **no** RPC,
  rate limit, or sanitiser in front of it.
- `public.pub_sessions` (`…000400:38-50`): `id`, `pub_id`, `host_user_id`, `name` (≤80), `status`,
  `started_at`, `ended_at`, `join_token_hash` (SHA-256 only, `…000850:126-131`), `created_at`,
  `updated_at`.
- `public.session_members` (`…000400:62-69`): `session_id`, `user_id`, `role`, `joined_at`, `left_at`.
- `public.user_pub_preferences` (`…000500:74-81`): `user_id`, `pub_id`, `hidden_from_favourites`,
  `created_at`, `updated_at`.
- `posts.place_label` (free text ≤80) and `posts.pub_id` (`…20260811000100_feed_tables.sql:38-39`).

Precise device location is requested When-In-Use, used transiently to bias MapKit search, and is
not written to any table (`CheekyPint/Core/Location/LocationService.swift:22,28`;
`docs/APP_PRIVACY_DATA_MAPPING.md:26`). What *is* stored is which venue the user selected and when —
see [DPIA.md](DPIA.md) §3.3.

### 4.7 Social memories — `public.clinks` / `public.clink_participants` (`…000500:52-68`)

`clinks`: `id`, `session_id`, `created_by`, `created_at`. `clink_participants`: `clink_id`,
`user_id`, `confirmed_at`.

### 4.8 Feed content (definer-only)

- `public.posts` (`…20260811000100_feed_tables.sql:33-50`): `id`, `author_id`, `body` (≤500),
  `image_path` (≤300, storage key), `place_label` (≤80), `pub_id`, `created_at`, `deleted_at`.
- `public.post_cheers` (`…000100:58-63`): `post_id`, `user_id`, `created_at`.
- `public.post_comments` (`…000100:68-75`): `id`, `post_id`, `author_id`, `body` (1–280),
  `created_at`, `deleted_at`.
- `public.comment_mentions` (`…000100:81-85`): `comment_id`, `mentioned_user_id`.

All four have RLS enabled with **no policies** and all privileges revoked from
`public`/`anon`/`authenticated` (`…000100:93-101`).

### 4.9 Social graph

- `public.friendships` (`…000300_social_tables.sql:7-18`): `id`, `requester_id`, `addressee_id`,
  `status` (`pending`/`accepted`/`declined`/`removed`), `requested_at`, `responded_at`,
  `updated_at`, and generated `user_low`/`user_high`. Readable by either party
  (`…000700_rls_policies.sql:60-62`).
- `public.blocks` (`…000300:39-45`): `blocker_id`, `blocked_id`, `created_at`. Readable by the
  blocker only (`…000700:68-69`) — the blocked person is never told.
- `public.nudges` (`…20260803000000_nudges.sql:4-11`): `id`, `sender_id`, `recipient_id`,
  `created_at`, `acknowledged_at`. Definer-only (`…000000_nudges.sql:25-26`).

### 4.10 Moderation data — `public.reports` (`…000300_social_tables.sql:52-62` + `…20260811000400_feed_reports.sql:3-5`)

`id`, `reporter_id`, `reported_user_id` (required at insert, nullable thereafter — see below),
`reported_user_key` (`not null`), `category` (`inappropriate_profile_image`,
`inappropriate_text`, `harassment`, `impersonation`, `underage_concern`, `other`,
`inappropriate_post_image` — `…000100_extensions_and_enums.sql:27-34`,
`…20260811000300_report_category_post_image.sql:4`), `details` (≤1000 chars of reporter-written
free text about a third party), `status` (`open`/`reviewing`/`actioned`/`dismissed`), `created_at`,
`reviewed_at`, `post_id`, `comment_id` (at most one of the two — `…20260811000400`). The
reporter can read their own reports (`…000700:74-75`); the reported person cannot.

`reported_user_key` is a sha256 digest over a domain-separated string containing the reported
account's id, stamped at insert and never rewritten. **Purpose:** a report survives deletion of the
account it concerns — `reported_user_id`, `post_id` and `comment_id` are all `on delete set null` —
and the key is what still allows reports about one former account to be grouped, on the Art. 17(3)(e)
basis recorded in [DPIA.md](DPIA.md) §3.7. **Limits, stated because they are easy to overstate:** the
key is pseudonymisation under Art. 4(5), not anonymisation — the retained row remains personal data
with a retention clock (§7) — and it **cannot** link a person to a new account, because a new
registration has a new account id and therefore an unrelated key. No cross-account identification is
performed or intended. The operational detail is in
[MODERATION_PROCESS.md](MODERATION_PROCESS.md) §6.

`status` and `reviewed_at` are written only by `public.review_report`
(`…20260813000100_review_report.sql`), which is revoked from `public`/`anon`/`authenticated` and
granted to `service_role`. `report_reviewed_at_matches_status` constrains the pair so a resolved
report always carries the review timestamp the retention purge keys off.

### 4.11 Operational and security data

- **`public.rate_limit_events`** (`…000600_security_helpers.sql:86-91`): `id` (bigint identity),
  `user_id`, `action` (e.g. `pint_create`, `report`, `data_export`), `created_at`. One row per
  protected call. This is a per-user behavioural log: it records that a specific user performed a
  specific class of action at a specific second, and it exists for every rate-limited action even
  when the underlying write was later deleted. RLS enabled with no policies (`…000700:147`); not
  included in `export_my_data()`.
- **`public.storage_gc_queue`** (`…20260812000200_storage_gc_queue.sql:8-17`): `id`, `bucket_id`,
  **`object_path`** — whose first path segment is the owner's user uuid (`post-images/<uid>/<file>`,
  `…20260811000200_feed_storage.sql:3`) — `enqueued_at`, `processed_at`, `attempts`, `last_error`
  (≤500 chars of storage-API error text, `…20260812000250_storage_gc_claim_marker.sql:31-34`).
  Definer-only (`…000200:25-26`). Rows are **marked** processed, never deleted
  (`…000200:55-64`), and no purge function exists for this table — see §9.8.

### 4.12 Storage objects

- **`avatars` bucket — public** (`…20260101000950_storage.sql:12-14`), with a blanket
  authenticated-read policy alongside it (`…000950:33-35`). Objects are fetched by the app over the
  unauthenticated public route (`CheekyPint/Core/Networking/SupabaseData.swift:106-107`,
  `CheekyPint/Core/Database/ProfileRepository.swift:124`), so avatar bytes are protected only by an
  unguessable filename, not by access control.
- **`post-images` bucket — private** (`…20260812000100_private_post_images.sql:14`), read-gated by
  `post_images_read_visible_posts` → `can_read_post_image`, which requires the requester to be the
  author of, or an accepted friend of the author of, a live post referencing that exact path
  (`…20260812000100:36-50,67-72`).

This asymmetry is real and current: **post photo bytes are access-controlled; avatar bytes are
not.**

### 4.13 Special categories (Art. 9) and criminal-offence data (Art. 10)

| | Status |
|---|---|
| Art. 9 | **Unresolved.** See §2.1 and [DPIA.md](DPIA.md) §3.1. If alcohol-consumption records are health data, §4.5 in its entirety is special-category data, and `flagged_high_frequency` is a derived inference about it. Not asserted either way here. |
| Art. 10 | None processed by design. `reports.details` is free text and could contain an allegation of criminal conduct written by a reporter; no field is designated for it and no such processing is intended. |

## 5. Recipients (Art. 30(1)(d))

| Recipient | Role | What they receive | Safeguard |
|-----------|------|-------------------|-----------|
| **Supabase** (`[[Supabase entity]]`) | Processor — hosting, Postgres, auth, storage, Edge Functions | All data in §4 | Art. 28 processor terms: `[[DPA reference / date]]` |
| **Apple** | Processor / independent controller for Sign in with Apple | Auth assertion, private-relay email | `[[Apple developer agreement reference]]` |
| **Other accepted friends of the data subject** | Recipients, not processors | Only the fields the subject's `privacy_settings` permit, gated by `is_accepted_friend` (`…000600_security_helpers.sql:26-41`) | Enforced server-side; see §8 |
| **Operator moderation staff** | Internal, under the controller | `reports` queue rows, including reporter identity and free text, and any content needed to triage | `[[access-control and confidentiality arrangements for moderators — none documented]]` |
| **`[[error-reporting / crash provider, if enabled]]`** | Not currently used | Nothing | `docs/APP_PRIVACY_DATA_MAPPING.md:24` lists crash data as conditional; no SDK is present |
| Advertising / analytics networks | **None** | Nothing | No third-party SDK of any kind is linked: the only package dependency is the local `CheekyPintCore` (`project.yml:26-28,53-55`; `CheekyPintCore/Package.swift`), and analytics is a no-op (`CheekyPint/Core/Analytics/AnalyticsService.swift:27-29`) |

No personal data is sold, and no cross-app tracking occurs
(`docs/APP_PRIVACY_DATA_MAPPING.md:3-4`).

## 6. Transfers to third countries (Art. 30(1)(e))

**Undetermined.** No Supabase project region has been chosen and no project is linked
(`docs/RELEASE_CHECKLIST.md:5` is an open item), so it is not currently possible to state whether
personal data will be processed outside the EEA.

| Field | Value |
|-------|-------|
| Supabase hosting region | `[[region]]` |
| Transfer occurs outside EEA? | `[[yes/no — depends on region]]` |
| Art. 46 mechanism, if applicable | `[[SCCs module 2 / adequacy decision, reference]]` |
| Transfer impact assessment | `[[not performed]]` |
| Supabase sub-processors | `[[list per Supabase sub-processor page, as of date]]` |
| Apple (Sign in with Apple) transfers | `[[per Apple's terms]]` |

Until the region is fixed, `docs/legal/PRIVACY_POLICY.md:52-55` cannot be completed either, and no
statement about third-country transfers should be published.

## 7. Retention periods (Art. 30(1)(f))

The published schedule is `docs/legal/DATA_RETENTION_POLICY.md`. The table below states, per
category, the function that actually enforces it.

> **Enforcement warning.** None of these functions is scheduled. There is no `pg_cron` job, no
> scheduled Edge Function invocation, and no scheduler configuration anywhere in this repository —
> only unchecked pre-launch checklist items (`docs/RELEASE_CHECKLIST.md:12-20`). Every purge
> function is also revoked from `authenticated` and runnable only by the service role
> (`…20260812000400_retention_purges.sql:119-122`; `…000600_security_helpers.sql:139-140`), so no
> user action triggers one either. **Until the operator schedules them, every "purged within N days"
> value below is aspirational and the published retention policy is not met in practice.**

| Data category | Published period | Enforcing function | Enforced today? |
|---|---|---|---|
| Profile, privacy settings | While the account is active | `delete_account()` (`…000850_rpc_pints_sessions.sql:254-284`) anonymises on request; hard removal by the `auth.users` cascade run by the Edge Function (`supabase/functions/delete-account/index.ts:69`) | Yes, on user request |
| Drink diary (`pint_entries`) | Soft-deleted on undo; purged within 30 days | `purge_soft_deleted_pint_entries(interval '30 days')` (`…20260812000400_retention_purges.sql:73-93`) | **No — unscheduled** |
| Posts and post bodies | Soft-deleted on author deletion; purged within 30 days | `purge_soft_deleted_posts(interval '30 days')` (`…000400:20-49`) | **No — unscheduled** |
| Post photo objects | Removed when the post is purged | Two-step: `delete_post` enqueues the path at soft-delete time (`…20260812000300_enqueue_deleted_post_images.sql:44-48`) and `purge_soft_deleted_posts` enqueues at purge time (`…000400:33-37`); the `storage-gc` Edge Function drains the queue and is the only thing that deletes the bytes (`supabase/functions/storage-gc/index.ts:57-100`) | **No — `storage-gc` is unscheduled** |
| Comments | Soft-deleted by author; purged within 30 days | `purge_soft_deleted_comments(interval '30 days')` (`…000400:51-71`) | **No — unscheduled** |
| Comments and cheers **by other users** on a purged post | Removed with the post | FK cascade from `posts` (`…20260811000100_feed_tables.sql:59,70`), documented deliberately at `…20260812000400:9-18` | Follows the (unscheduled) post purge |
| Reports, resolved | 12–24 months after resolution | `purge_resolved_reports(interval '18 months', …)` (`…20260812000400_retention_purges.sql`) | **No — unscheduled.** Note this function had never deleted a row before `public.review_report` existed: its predicate needs `status` and `reviewed_at`, and nothing in the schema ever set either (`…20260813000100_review_report.sql`) |
| Reports, unresolved, reported account still active | Published as having no defined period | **None, deliberately.** A scheduled job here would destroy open safety complaints; the control is working the queue ([MODERATION_PROCESS.md](MODERATION_PROCESS.md) §7) | No limit exists |
| Reports, unresolved, reported account deleted | 24 months from filing | Second branch of `purge_resolved_reports`, keyed on `created_at` because a never-resolved report has no `reviewed_at` (`…20260812000400_retention_purges.sql`) | **No — unscheduled** |
| Reports **about** a deleted account | Retained without the reported person's identity | `reported_user_id`, `post_id` and `comment_id` are `on delete set null`; `reported_user_key` keeps a pseudonym for the former subject (`…20260101000300_social_tables.sql`, `…20260811000400_feed_reports.sql`) | Yes — the row survives; its own clock (rows above) then applies |
| Reports **filed by** a deleted account | Not published | `reporter_id` is still `on delete cascade` to `profiles`, which cascades from `auth.users` (`…000200_core_tables.sql:7`), so a departing user's own reports — including open reports about third parties — are destroyed with their account. Separate operator decision, not yet taken ([MODERATION_PROCESS.md](MODERATION_PROCESS.md) §8) | Immediate deletion, not retention |
| Friendships, blocks | Until removed / unblocked | `delete_account()` deletes both for the departing user (`…000850:277-278`) | Yes, on user request |
| Friend tokens | Until revoked or regenerated | `regenerate_friend_token` revokes prior tokens (`…000800_rpc_social.sql:23-25`); `delete_account()` deletes them (`…000850:276`) | Yes |
| Nudges | Not published | **None.** No purge function; removed only by the `profiles` cascade on account deletion | No limit exists |
| Rate-limit events | Rolling 2 days | `prune_rate_limit_events(interval '2 days')` (`…000600_security_helpers.sql:130-137`) | **No — unscheduled** |
| `storage_gc_queue` rows | Not published | **None.** `mark_storage_gc_done` sets `processed_at` and never deletes (`…20260812000200:55-64`). The uid-bearing `object_path` persists indefinitely. See §9.8 | No limit exists |
| Avatar objects | Removed on account deletion | `delete-account` Edge Function empties the user's `avatars` folder (`supabase/functions/delete-account/index.ts:52-55`) | Yes, on user request |
| Analytics events | 14 months (if ever enabled) | No sink exists; nothing is collected (`CheekyPint/Core/Analytics/AnalyticsService.swift:27-29`) | Moot |
| Backups, auth logs | `[[7–30 days]]` / `[[per Supabase configuration]]` | Supabase platform settings, not this repository | `[[unconfigured]]` |

## 8. Technical and organisational measures (Art. 30(1)(g), Art. 32)

### 8.1 Deny-by-default database access

- **RLS with no policies** — deny-all for every client role, access only through `security definer`
  RPCs: `posts`, `post_cheers`, `post_comments`, `comment_mentions`
  (`…20260811000100_feed_tables.sql:93-101`), `nudges` (`…20260803000000_nudges.sql:25-26`),
  `rate_limit_events` (`…000700_rls_policies.sql:144-147`), `storage_gc_queue`
  (`…20260812000200:25-26`).
- **Self-only RLS** everywhere a client does read directly: `profiles` (`…000700:26-37`),
  `privacy_settings` (`…000700:42-47`), `friend_tokens` (`…000700:53-54`), `friendships` — either
  party (`…000700:60-62`), `blocks` — blocker only (`…000700:68-69`), `reports` — reporter only
  (`…000700:74-75`), `pint_entries` — owner only (`…000700:135-136`), `user_pub_preferences`
  (`…000700:141-142`). The stated design intent is that if you can read a `profiles` row at all, it
  is your own (`…000700:3-7`).
- **Function grants are least-privilege**: `anon` can execute nothing;
  `authenticated` gets only the client RPCs (`…000900_grants.sql:6-7`), with internal plumbing
  individually revoked (`…000900:10-13`) and future functions defaulted to revoked (`…000900:16`).
- **Relationship oracles are no longer client-callable.** `is_accepted_friend`, `is_blocked`,
  `can_view_profile` and `shares_active_session` were executable by `authenticated` — any user could
  ask whether two arbitrary people were friends, or whether a specific pair had blocked each other.
  Revoked at `…20260812000600_revoke_helper_oracles.sql:20-23`. `can_view_post` was revoked from
  `authenticated` when it was introduced (`…20260811000600_rpc_feed_social.sql:227`).

### 8.2 Access rules applied by the RPC layer

- Every `security definer` function sets `search_path = ''` and schema-qualifies every identifier,
  preventing search-path privilege escalation (pattern throughout; rationale at
  `…000600_security_helpers.sql:3-6`).
- Feed visibility is "self or accepted friend", evaluated per request in `feed_page`
  (`…20260811000500_rpc_feed_posts.sql:160`), `post_comments_page`
  (`…20260811000600_rpc_feed_social.sql:204`) and `can_view_post` (`…000600:5-19`), which the
  cheer/comment/report entry points re-check rather than trusting a caller who holds a post id
  (used at `…000600:33,82,204`; `…20260811000700_rpc_feed_reports.sql:20,61`).
- `is_accepted_friend` is block-aware **in both directions**: it calls `is_blocked`, which matches a
  block row written by either party (`…000600_security_helpers.sql:10-22,26-41`).
- Field-level privacy is applied inside the RPCs, not by the client: avatar and city gating in
  `get_friends` / `get_friend_profile` (`…000800_rpc_social.sql:247-248,315-317`), per-period total
  gating that degrades to a "private" marker rather than a fake zero (`…000800:363-390`).
- Uniform error messages on token resolution and profile lookup to prevent enumeration
  (`…000800:63-68,299`).
- @-mentions are restricted to the commenter's own accepted friends, and a friend who cannot
  independently see the post is silently dropped rather than rejected distinguishably, so the
  rejection cannot be used to probe someone else's graph
  (`…20260811000600_rpc_feed_social.sql:106-114`).

### 8.3 Storage

- Writes are confined to the uploader's own `<uid>/` folder in both buckets
  (`…000950_storage.sql:17-31`; `…20260811000200_feed_storage.sql:16-30`), and `create_post`
  independently rejects a path outside the caller's folder and any path containing `..`
  (`…20260811000500_rpc_feed_posts.sql:42-55`).
- `post-images` is private, with reads authorised per request against the friend graph
  (`…20260812000100_private_post_images.sql:14,36-50,67-72`).
- **`avatars` remains a public bucket** (`…000950_storage.sql:12-14`) — an unmitigated asymmetry,
  stated as such in §4.12 and [DPIA.md](DPIA.md) §3.5.
- Deletion of a post enqueues its photo for byte-level removal before returning, because the row is
  the only place the path is recorded (`…20260812000300_enqueue_deleted_post_images.sql:44-48`);
  the `storage-gc` Edge Function is service-role-gated (`supabase/functions/storage-gc/index.ts:49-51`)
  and claims work with `for update skip locked` plus a rising `attempts` count
  (`…20260812000250_storage_gc_claim_marker.sql:4-23`).

### 8.4 Input handling

- Server-side sanitiser `strip_ugc_control_chars` strips control, zero-width and bidi-override
  characters (`…20260811000100_feed_tables.sql:12-28`), applied to post bodies, place labels and
  image paths (`…20260811000500_rpc_feed_posts.sql:26-30`) and comment bodies
  (`…20260811000600_rpc_feed_social.sql:88`).
- Database-level length and format constraints on every user-supplied field (see §4).
- **Profile `display_name`, `bio` and `city` are sanitised client-side only.** There is no
  profile-update RPC; `profiles_update_self` permits direct DML with only an ownership check
  (`…000700_rls_policies.sql:34-37`), and sanitisation lives in the app
  (`CheekyPint/Features/Settings/EditProfileView.swift:137-139`). A client that skips it is not
  stopped. The same applies to the username reserved-word list (`docs/MODERATION.md:116-123`).
- **`pubs` inserts have no rate limit and no sanitiser**, and `formatted_address` has no length cap
  (`…000400_pub_tables.sql:6-21`; `…000700_rls_policies.sql:84-85`).

### 8.5 Abuse limits

`enforce_rate_limit` counts the caller's rows for an action in a trailing window and raises before
recording the attempt (`…000600_security_helpers.sql:100-127`). Enforced actions and caps:
`friend_token_regenerate` 10/h, `friend_token_resolve` 30/h, `friend_request` 30/h
(`…000800_rpc_social.sql:21,53,99`), `report` 20/h (`…000800:220`;
`…20260811000700_rpc_feed_reports.sql:29,68`), `pint_create` 60/h, `session_create` 20/h,
`session_join` 30/h, `clink_create` 30/h (`…000850_rpc_pints_sessions.sql:41,124,158,219`),
`nudge_send` 30/h (`…20260803000000_nudges.sql:45`), `post_create` 20/h
(`…20260811000500_rpc_feed_posts.sql:24`), `post_delete` 60/h
(`…20260812000300_enqueue_deleted_post_images.sql:31`), `post_comment` 60/h, `comment_delete` 60/h,
`cheers_toggle` 120/h (`…20260811000600_rpc_feed_social.sql:86,140,37`), `data_export` 5 per 24 h
(`…20260812000500_export_my_data.sql:109`).

Not every mutation is rate-limited: `undo_recent_pint_entry`, `leave_session`, `end_session`
(`…000850:89,178,192`), `respond_to_friend_request`, `remove_friend`, `block_user`, `unblock_user`
(`…000800:121,149,167,190`), `delete_account` (`…000850:254`), and all direct DML on `profiles`,
`privacy_settings`, `user_pub_preferences` and `pubs` carry no limit.

### 8.6 Credential and secret handling

Raw friend tokens and session join tokens are never persisted — only SHA-256 hashes
(`…000800_rpc_social.sql:27-31`; `…000850_rpc_pints_sessions.sql:126-131`). The service-role key
exists only in the Edge Function environment and never reaches the client
(`supabase/functions/delete-account/index.ts:12`; `docs/SECURITY.md:5-6`). Session tokens are stored
in the iOS Keychain (`CheekyPint/Core/Authentication/KeychainStore.swift:24`).

### 8.7 Data-subject rights machinery

- **Access / portability:** `export_my_data()` returns one caller-scoped JSON document covering 14
  collections — profile, privacy settings, pint entries, posts, comments (with the mentions the
  caller made), cheers given, friendships, blocks placed, reports filed (with `reported_user_id`
  redacted under Art. 15(4)), pub preferences, hosted sessions, session memberships, Nudges sent and
  Nudges received — every subquery filtered to `auth.uid()`, each collection capped at 10,000 rows
  with a top-level `truncated` flag (`…20260812000500_export_my_data.sql:81-403`, cap at `:89`, flag
  at `:378`). `friend_tokens` and `pub_sessions.join_token_hash` are deliberately excluded as live
  credentials (`…000500:63-72`). **No client entry point exists — see §9.1.**
- **Erasure:** `delete_account()` anonymises the profile, deletes friend tokens, friendships and
  blocks, ends session memberships and soft-deletes the diary
  (`…000850_rpc_pints_sessions.sql:254-284`); the `delete-account` Edge Function then empties both
  the `avatars` and `post-images` folders and deletes the auth user, aborting before auth deletion
  if storage cleanup fails so the request can be retried
  (`supabase/functions/delete-account/index.ts:45-70`). The app invokes the Edge Function, not the
  bare RPC, with a regression test pinning that (`CheekyPint/Core/Database/ProfileRepository.swift:98-101`;
  `CheekyPintTests/DeleteAccountWiringTests.swift:52-61`).
- **Rectification:** direct owner-scoped DML on `profiles` / `privacy_settings`
  (`…000700_rls_policies.sql:34-37,46-47`).
- **Objection / restriction / complaint handling:** no technical mechanism; process is an open
  checklist item (`docs/RELEASE_CHECKLIST.md:55`).

### 8.8 Verification

`supabase/tests/rls_rpc_suite.sql`, run by `supabase/tests/run_local_pg.sh`, asserts allowed and
denied paths across RLS and every RPC (87 checks pass on this revision).

### 8.9 Organisational measures

`[[Not documented: staff roles and authorisations, moderator access control and logging, breach
detection and Art. 33 notification procedure, processor review cadence, training, retention-job
monitoring ownership.]]` Only two operational monitoring items exist in writing
(`docs/RELEASE_CHECKLIST.md:21-23`).

## 9. Accuracy notes and known gaps

Recorded here rather than omitted, because an Art. 30 record that overstates enforcement is worse
than one that admits a gap.

1. **Art. 15/20 self-service export has no client entry point.** `export_my_data()` exists and is
   granted to `authenticated` (`…20260812000500_export_my_data.sql:402-403`), but no Swift code
   calls it — there is no export screen in the shipped app. `docs/PRIVACY.md:36-37` and
   `docs/legal/PRIVACY_POLICY.md:65` both state that in-app export is available; that is **not yet
   true**. Requests must currently be served manually by the operator.
2. **Nudges the caller sent are readable by no path in the app.** `public.nudges` is revoked with no
   policies (`…20260803000000_nudges.sql:25-26`) and `get_received_nudges()` reads only the
   recipient side (`…000000_nudges.sql:107`). `export_my_data()`'s `nudges_sent` collection
   (`…20260812000500:343-357`) is the only read path that exists anywhere — and per §9.1 nothing
   invokes it. An Art. 15 access gap.
3. **Published retention periods are not enforced.** No purge job is scheduled anywhere (§7).
4. **A photo URL fetched while access was permitted cannot be recalled.** Revocation — unfriending,
   blocking, post deletion, account deletion — stops *future* authorisation; it cannot retrieve
   bytes already downloaded. Acknowledged in `docs/legal/DATA_RETENTION_POLICY.md:40-42` and
   `docs/legal/ACCOUNT_DELETION_POLICY.md:20-24`.
5. **Deleting a post erases other users' comments and cheers on it** at purge time, via FK cascade
   (`…20260811000100_feed_tables.sql:59,70`), deliberately and with reasoning recorded at
   `…20260812000400_retention_purges.sql:9-18`. One user's action erases another user's personal
   data.
6. **`docs/legal/*` are unreviewed templates** whose numeric values are largely `[[bracketed]]`
   (`docs/legal/DATA_RETENTION_POLICY.md:3-4,16,20-24`). Retention figures cited in §7 are drawn
   from function defaults in code, not from a reviewed policy.
7. **Profile text and username rules are client-side only; `pubs` inserts are unconstrained** (§8.4).
8. **`storage_gc_queue` retains a user-identifying path indefinitely.** Rows are marked processed,
   never deleted (`…20260812000200:55-64`), and `object_path` embeds the owner's uuid. No purge
   function covers this table, so a record that user X once had a photo at a given path — plus any
   `last_error` text — outlives both the photo and, potentially, the account.
9. **Account deletion still destroys moderation reports filed *by* the deleted user** (narrowed
   2026-08-13). Reports **about** a deleted account now survive, minimised and pseudonymised
   (`…20260101000300_social_tables.sql`, `…20260811000400_feed_reports.sql`), which resolves the
   contradiction with `docs/legal/ACCOUNT_DELETION_POLICY.md` and lets the retention clock in
   `purge_resolved_reports` actually run. `reporter_id` still cascades, so a departing user's own
   reports — including open reports about third parties — are destroyed with their account; that is a
   separate decision the operator has not taken ([MODERATION_PROCESS.md](MODERATION_PROCESS.md) §8).
   Outstanding for the part that was done: counsel sign-off on the Art. 17(3)(e) basis and on the
   18-month / 24-month periods. See [DPIA.md](DPIA.md) §3.7.
10. **Supabase region unchosen**, so third-country transfer status is undetermined (§6).
11. **The feed is backend-only on this revision.** No feed screens, and no post/comment/cheer RPC
    contracts, exist in the app (`CheekyPint/Features/` contains no feed feature; no Swift file
    references `feed_page`, `create_post`, `add_comment` or `toggle_post_cheers`). The processing in
    P4 is fully implemented and reachable by any authenticated API client, but it is not yet exposed
    to users. `docs/MODERATION.md:57-70` and `docs/PRIVACY.md:43-51` still describe `post-images` as
    a public bucket, which `…20260812000100_private_post_images.sql:14` changed; `docs/SECURITY.md:27-30`
    still describes the relationship helpers as client-executable, which
    `…20260812000600_revoke_helper_oracles.sql:20-23` changed. Those three documents are stale, not
    this one.
12. **No breach-notification, moderator-access, or training documentation exists** (§8.9).

---

**Version:** `[[date of adoption]]` · **Reviewed by:** `[[reviewer]]` · **Next review:**
`[[date]]` · Maintained alongside [DPIA.md](DPIA.md) and re-verified against the migrations on every
schema change.
