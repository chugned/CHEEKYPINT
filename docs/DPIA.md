# Data Protection Impact Assessment (DSGVO / GDPR Art. 35)

> **Status: draft prepared from the shipped code, awaiting qualified legal review and operator
> sign-off.** It has not been reviewed by a lawyer or a DPO, and §8 is deliberately unsigned.
> `[[Double-bracketed]]` values depend on decisions the operator has not yet made, following the
> convention in `docs/legal/`. Nothing here is legal advice.
>
> **Method.** Every claim about what the system enforces cites the code that enforces it as
> `file:line`, in the style of [MODERATION.md](MODERATION.md). Data categories, recipients and
> retention are enumerated in [RECORDS_OF_PROCESSING.md](RECORDS_OF_PROCESSING.md) and are not
> repeated here in full. Where a control is absent, this document says so rather than describing the
> intent as if it were shipped.
>
> **The central question in this assessment — whether an alcohol-consumption diary is
> special-category health data under Art. 9 — is unresolved and is not resolved here.** It is set out
> in [§3.1](#31-risk-1--the-diary-may-be-special-category-health-data-art-9-unresolved). An operator
> reading this document must not treat its completion as evidence that the question has been
> answered.

---

## 1. Whether a DPIA is required

| Art. 35(3) trigger | Applicability |
|---|---|
| (a) Systematic and extensive automated evaluation / profiling with significant effects | **No.** The only automated inferences are `pint_entries.flagged_high_frequency`, non-punitive audit metadata never surfaced in the UI (`supabase/migrations/20260101000850_rpc_pints_sessions.sql:59-64`; `…20260101000500_pint_and_clink_tables.sql:23-24`), and an on-device tone choice that softens the confirmation message after clustered entries and stores nothing (`CheekyPintCore/Sources/CheekyPintCore/Utilities/WelfareMonitor.swift:39-45`). No decision with legal or similarly significant effect is automated. |
| (b) Processing on a large scale of Art. 9 special categories | **Undetermined — this is the deciding question.** If the drink diary is health data, this trigger is engaged as soon as the user base is non-trivial, and a DPIA becomes mandatory rather than prudent. See §3.1. |
| (c) Systematic monitoring of a publicly accessible area on a large scale | **No.** No public surface exists; the highest visibility ceiling in the schema is "accepted friends" (`…20260101000100_extensions_and_enums.sql:10-12`). |

Also relevant: the Austrian Datenschutzbehörde's published DPIA blacklist and the EDPB's nine
criteria (WP248) — `[[operator to check the current DSB list against this processing:
https://www.dsb.gv.at — not assessed here]]`. Independently of whether Art. 35 compels it, this
assessment is being performed because the processing combines sensitive-by-nature consumption data,
photographs, location-adjacent venue data and a social graph.

## 2. Description of the processing (Art. 35(7)(a))

### 2.1 Nature and purposes

CheekyPint is an iOS app with a Supabase backend (Postgres, auth, storage, Edge Functions) and no
other server-side component. Its purposes are enumerated as P1–P12 in
[RECORDS_OF_PROCESSING.md §2](RECORDS_OF_PROCESSING.md#2-purposes-of-processing-art-301b). In short:
a private drink diary, plus optional friends-only sharing of totals, venues, posts, photos and
comments, plus the safety and account machinery required to run that.

### 2.2 Scope of data

Fully enumerated in [RECORDS_OF_PROCESSING.md §4](RECORDS_OF_PROCESSING.md#4-categories-of-personal-data).
The features that drive this assessment:

- **Per-drink records** with a user-adjustable `occurred_at`, a server-authoritative `created_at`,
  `serving_type`, `volume_ml`, an `alcohol_free` flag, an optional 280-character private note and an
  optional `pub_id` (`…20260101000500_pint_and_clink_tables.sql:7-30`), retained for the life of the
  account.
- **Photographs** uploaded to two storage buckets, one private and one public (§3.2, §3.5).
- **A venue trail**: which pub was selected and when, via `pint_entries.pub_id`, `posts.pub_id` and
  the free-text `posts.place_label` (`…20260811000100_feed_tables.sql:38-39`).
- **A friend graph** with directed friendship edges, blocks and mentions
  (`…20260101000300_social_tables.sql:7-45`; `…20260811000100_feed_tables.sql:81-85`).
- **A moderation queue** with reporter-written free text about a named third party
  (`…20260101000300_social_tables.sql:52-62`).

### 2.3 Context

- **Data subjects** are adults who self-declare they meet their local legal drinking age — a
  timestamp the client sets directly, with no verification
  (`…20260101000200_core_tables.sql:20,29`; `CheekyPint/Core/Database/ProfileRepository.swift:80-83`).
  The store rating is 17+ (`docs/RELEASE_CHECKLIST.md:47`).
- **Relationship** is direct business-to-consumer; the subject is the source of nearly all data.
- **The subject-matter is sensitive by nature** regardless of its Art. 9 classification: alcohol
  consumption is stigmatised, is relevant to employment, insurance, custody and immigration
  decisions, and can carry religious and family significance. A disclosure that is technically minor
  can be materially harmful.
- **No third-party SDKs, no advertising, no tracking, no data sales** — the only linked package is
  the project's own `CheekyPintCore` (`project.yml:26-28,53-55`), and analytics ships as a no-op with
  a nine-event allowlist carrying no personal data
  (`CheekyPint/Core/Analytics/AnalyticsService.swift:6-29`).
- **Deployment status.** The backend feed (posts, photos, cheers, comments, mentions) is fully
  implemented and reachable by any authenticated API client, but no feed screens ship in the app on
  this revision, and `export_my_data()` has no client entry point. This assessment covers the
  processing as implemented in the backend, and flags both gaps where they bear on risk
  (§3.9, §4.4).

### 2.4 Data flows and where authorisation happens

1. The app holds only the Supabase anon key and a per-user JWT; the service-role key exists only
   inside Edge Function environments (`docs/SECURITY.md:5-6`;
   `supabase/functions/delete-account/index.ts:12`).
2. Cross-user reads never touch a table directly. Feed tables have RLS enabled with **no policies**
   and every privilege revoked (`…20260811000100_feed_tables.sql:93-101`), as do `nudges`
   (`…20260803000000_nudges.sql:25-26`), `rate_limit_events` (`…20260101000700_rls_policies.sql:147`)
   and `storage_gc_queue` (`…20260812000200_storage_gc_queue.sql:25-26`). Reads go through
   `security definer` RPCs that re-derive visibility per call.
3. The visibility rule is "self or accepted friend", evaluated by `is_accepted_friend`, which is
   block-aware in both directions because it calls `is_blocked`
   (`…20260101000600_security_helpers.sql:10-22,26-41`), applied in `feed_page`
   (`…20260811000500_rpc_feed_posts.sql:160`), `post_comments_page`
   (`…20260811000600_rpc_feed_social.sql:204`) and `can_view_post` (`…20260811000600:5-19`).
4. Photo **bytes** in `post-images` are authorised by the same rule: the bucket is private and its
   `select` policy calls `can_read_post_image`, which requires a live post at that exact path
   authored by the requester or by an accepted friend
   (`…20260812000100_private_post_images.sql:14,36-50,67-72`). Avatar bytes are **not** so protected
   (§3.5).
5. Erasure spans three systems: the `delete_account()` RPC anonymises and tears down
   (`…20260101000850_rpc_pints_sessions.sql:254-284`), the `delete-account` Edge Function empties both
   storage folders and deletes the auth user (`supabase/functions/delete-account/index.ts:45-70`), and
   deferred byte deletion for individual posts is queued in `storage_gc_queue`
   (`…20260812000300_enqueue_deleted_post_images.sql:44-48`) and drained by the `storage-gc` Edge
   Function (`supabase/functions/storage-gc/index.ts:57-100`).

## 3. Risks to data subjects (Art. 35(7)(c))

Severity is judged from the perspective of the data subject, per Art. 35(1), not from the operator's.

### 3.1 Risk 1 — the diary may be special-category health data (Art. 9). **Unresolved.**

**What the system does.** For each authenticated, named user it stores every drink they choose to
log: when (`occurred_at`, plus a server timestamp the user cannot alter), what size
(`serving_type`, `volume_ml`), whether alcohol-free, optionally where (`pub_id`), and optionally a
free-text note — indefinitely, in a form that is trivially aggregated into daily, weekly, monthly and
yearly consumption (`…20260101000500_pint_and_clink_tables.sql:7-30`; aggregation already implemented
in `get_friend_leaderboard`, `…20260101000800_rpc_social.sql:379-388`). It additionally derives and
stores a behavioural inference about drinking pace, `flagged_high_frequency`, set when the user logs
12 or more entries in an hour or logs within 60 seconds of the previous entry
(`…20260101000850_rpc_pints_sessions.sql:59-64`).

**The question.** Is that data set "data concerning health" within Art. 4(15), and therefore special
category under Art. 9(1)? Arguments exist in both directions, and this document deliberately
advances neither as its conclusion:

- It is not a clinical measurement, a diagnosis, or data from a health professional, and a user's own
  record of a social activity is not obviously health data.
- Equally, longitudinal alcohol-consumption volume is a recognised health indicator; the CJEU and
  EDPB have read "data concerning health" broadly, including data from which health information can
  be *inferred*; and `flagged_high_frequency` is precisely such an inference, computed and stored by
  the controller rather than the user.

**What turns on the answer.**

| If the diary is *not* Art. 9 data | If the diary *is* Art. 9 data |
|---|---|
| Art. 6(1)(b) contract may suffice, as the current template assumes (`docs/legal/PRIVACY_POLICY.md:34`) | An Art. 9(2) condition is additionally required. In practice only explicit consent under Art. 9(2)(a) is available to this app — so the diary would need separate, explicit, freely-withdrawable consent, distinct from accepting the terms, and the app would need to work in a meaningful way for a user who refuses |
| DPIA prudent, not mandatory | Art. 35(3)(b) is likely engaged: DPIA mandatory, and Art. 37(1)(c) DPO appointment must be reassessed |
| `docs/legal/PRIVACY_POLICY.md:28` and `docs/APP_PRIVACY_DATA_MAPPING.md:31`, which both state that no health data is collected, are accurate | Both statements are **inaccurate and must be corrected**, and the App Store privacy declaration would need to change |
| Friends-only sharing of totals is an ordinary privacy choice | Every share of a total to a friend is a disclosure of special-category data, and the friends-only defaults in `privacy_settings` (`…20260101000200_core_tables.sql:40-53`) would need to be re-examined against Art. 9 rather than only against data minimisation |

**Assessment: unresolved. This requires qualified Austrian legal advice before launch**, and it must
be obtained by someone who is not the party that benefits from the convenient answer. The technical
measures in §4 are the same either way; the lawful basis, the consent flow, the DPO assessment and
the public statements are not. No risk score is assigned here, because the score is a function of the
answer.

**Nothing in the codebase currently implements an Art. 9 consent flow.** If counsel answers that the
diary is health data, the onboarding consent step, its withdrawal path, and a record of consent are
all new work.

### 3.2 Risk 2 — photographs contain third parties who never consented, and no mechanism exists for them

**What the system does.** Users upload avatar images and post photos. A pub photo very often contains
people who are not users of the app: other customers, staff, and the user's companions. Nothing in
the schema records who is depicted, and there is no field, flow, or notice for a depicted person.

**Risk to the depicted non-user.** They are a data subject whose image is being processed by a
controller they have never heard of, in a context that associates them with a drinking occasion, at a
named venue, at a known time (`posts.place_label` / `posts.pub_id`,
`…20260811000100_feed_tables.sql:38-39`). They cannot be informed (Art. 14), cannot request access or
erasure because neither they nor the operator can locate their image, and cannot object. This is the
one category of data subject for whom the app provides **no rights mechanism at all**.

**Mitigations that do exist.** Distribution is narrow and enforced server-side: friends-only via
`feed_page` (`…20260811000500_rpc_feed_posts.sql:160`); the photo bytes themselves are
access-controlled by the friend graph, not merely unlisted, because `post-images` is private with a
friend-aware read policy (`…20260812000100_private_post_images.sql:14,36-50,67-72`); reporting exists
for content that should not have been shared (`…20260811000700_rpc_feed_reports.sql:4-76`); post
deletion queues the bytes for removal (`…20260812000300_enqueue_deleted_post_images.sql:44-48`).

**Mitigations that do not exist.** No consent prompt or reminder before uploading a photo containing
others; no face detection or blurring; no notice-to-depicted-person mechanism (which is arguably
impossible); and a report can only be filed by someone who can already see the post — i.e. a friend
of the poster — so a depicted non-user cannot report their own image. **Residual risk: high
likelihood, moderate-to-high severity, only partially mitigated.** `[[Operator decision: whether to
add an upload-time reminder about photographing others, and whether that is sufficient.]]`

### 3.3 Risk 3 — location inference: a movement-and-consumption profile

**What the system does.** No precise device location is stored — location is requested When-In-Use,
used transiently to bias MapKit search, and never written to a table
(`CheekyPint/Core/Location/LocationService.swift:22,28`; `docs/APP_PRIVACY_DATA_MAPPING.md:26`). What
*is* stored is stronger than it first appears:

- `pint_entries.pub_id` + `occurred_at` — this person was at this named venue at this time, and drank
  (`…20260101000500_pint_and_clink_tables.sql:7-30`);
- `pubs.latitude` / `pubs.longitude` — the venue's exact coordinates
  (`…20260101000400_pub_tables.sql:16-17`);
- `posts.place_label` — free text the user typed, capped at 80 characters and control-stripped but
  otherwise unconstrained, so it can hold anything including an address
  (`…20260811000100_feed_tables.sql:38`);
- `pub_sessions` + `session_members` — who else was there, and for how long
  (`…20260101000400_pub_tables.sql:38-69`).

Joined over time, that is a dated movement trail with a consumption quantity attached to each point,
and with companions attached to some. `get_favourite_pubs` already computes the "where does this
person usually drink" view, including a shared-visit count with the viewer
(`…20260101000800_rpc_social.sql:397-448`). Home and workplace are inferrable from a long enough
trail even without any coordinate of the user's own.

**Mitigations.** Venue attachment is optional per entry (`pub_id` is nullable). `city_visibility` and
`favourite_pubs_visibility` default to `private`, i.e. off
(`…20260101000200_core_tables.sql:49` and `:44`), and `get_favourite_pubs` refuses unless the target
is the caller, an accepted friend, and has that switch on (`…20260101000800:415-421`). Raw entries are
never visible to anyone but their owner (`…20260101000700_rls_policies.sql:135-136`); friends see
counts, never rows. Users can exclude specific pubs from the favourites calculation
(`user_pub_preferences.hidden_from_favourites`, `…20260101000500:74-81`). No background location is
requested at all.

**Residual.** The profile still exists in the database, and any compromise of the operator's Supabase
project, or any lawful-access request, exposes it in full. Its existence is also not obvious to the
user, who experiences the feature as "tagging a pub". **Residual risk: moderate likelihood, high
severity if disclosed.** `[[Operator decision: whether to offer a retention cap on venue attachment
separate from the diary itself.]]`

### 3.4 Risk 4 — re-identification and inference through the friend graph, even with quantities hidden

**What the system does.** A user can hide their totals: with `weekly_total_visibility = 'private'`,
`get_friend_leaderboard` returns `0` with an `is_private` marker rather than a count
(`…20260101000800_rpc_social.sql:379-390`). That protects the number. It does not make the person
absent:

- they still appear in the leaderboard row set, and their `display_name` is returned
  (`…20260101000800:376-377`), so "this person uses a drinking diary" is disclosed to every accepted
  friend regardless of every privacy switch;
- membership of the same pub session is visible to co-members
  (`…20260101000700_rls_policies.sql:107-109`), so co-presence leaks even when quantities do not;
- `feed_page.cheers_count` and `post_comments_page.mentioned_user_ids` retain narrow aggregate
  residues after a block — a pre-block cheer still counts toward the total, and a pre-block mention
  still leaves an opaque uuid in the array (`docs/MODERATION.md:77-82`);
- a friend graph of even modest size is itself identifying: `friendships` is readable by either party
  (`…20260101000700_rls_policies.sql:60-62`), and a user's set of friends is close to unique.

**Mitigations.** There is no public directory and no global leaderboard; friend discovery requires a
256-bit opaque token whose raw value is never stored, only its SHA-256 hash
(`…20260101000800_rpc_social.sql:27-31`), and token resolution is rate-limited to 30 per hour with a
uniform failure message so it cannot be used to enumerate accounts (`…20260101000800:53,63-68`).
Relationship helpers are no longer callable by clients, so a user can no longer ask the server
whether two arbitrary people are friends or have blocked each other
(`…20260812000600_revoke_helper_oracles.sql:20-23`) — before that migration, any authenticated user
could (`docs/SECURITY.md:27-30` still describes the old behaviour and is stale).

**Residual.** "Hide my numbers" is not "hide my participation", and a user may reasonably read the
privacy switches as offering the latter. **Residual risk: high likelihood, low-to-moderate severity.**
`[[Operator decision: whether the privacy-settings screen should state explicitly that hiding a total
does not hide participation.]]`

### 3.5 Risk 5 — a photo URL fetched while access was permitted cannot be recalled; and avatars are not access-controlled at all

Two related exposures, of different current severity.

**(a) Post photos — irrevocability of copies already taken.** `post-images` is now private and every
byte fetch is authorised against the friend graph at request time
(`…20260812000100_private_post_images.sql:14,36-50,67-72`), so unfriending, blocking, deleting the
post or deleting the account all revoke *future* access immediately. What none of that can do is
retrieve a copy already downloaded: a friend who fetched the image while authorised, or
screenshotted it, holds it permanently. Post deletion queues the bytes for removal
(`…20260812000300_enqueue_deleted_post_images.sql:44-48`) and the `storage-gc` Edge Function deletes
them (`supabase/functions/storage-gc/index.ts:57-100`), which removes the server's copy only. This is
inherent to sharing an image with another person's device, not a defect, and it is already disclosed
to users (`docs/legal/DATA_RETENTION_POLICY.md:40-42`;
`docs/legal/ACCOUNT_DELETION_POLICY.md:20-24`). **Residual risk: certain likelihood, moderate
severity, not further mitigable by technical means.**

**(b) Avatars — a genuinely unmitigated asymmetry.** The `avatars` bucket is still `public = true`
(`…20260101000950_storage.sql:12-14`), and the app fetches avatar bytes over the unauthenticated
public route (`CheekyPint/Core/Networking/SupabaseData.swift:106-107`;
`CheekyPint/Core/Database/ProfileRepository.swift:124`). Protection is an unguessable filename, not
access control. Consequences: a leaked or forwarded avatar URL keeps working after unfriending,
blocking, and profile-photo replacement, for anyone on the internet, with no `Authorization` header
and no RLS evaluation. `avatar_visibility` gates whether the *path* is returned by an RPC
(`…20260101000800_rpc_social.sql:247,315`), which does nothing once a URL has escaped. Account
deletion does delete the objects (`supabase/functions/delete-account/index.ts:52-55`), which is the
one place the exposure is bounded. **This is the single clearest unmitigated technical gap in the
system, and it is a strictly smaller job than the one already done for post photos** — the pattern is
already in the repository (`…20260812000100_private_post_images.sql`). **Residual risk: moderate
likelihood, moderate-to-high severity, unmitigated.** `[[Operator decision: close before launch, or
accept and document the acceptance with a date.]]`

### 3.6 Risk 6 — moderation is reactive only: no proactive image or text scanning

**What the system does.** Nothing scans content on upload. There is no image classifier, no nudity or
CSAM detection, no text classifier, and no keyword filter. What exists is
report-driven: `report_user`, `report_post` and `report_comment` all write to one queue
(`…20260101000800_rpc_social.sql:204-228`; `…20260811000700_rpc_feed_reports.sql:4-76`), with
categories including inappropriate profile image, inappropriate post image, inappropriate text,
harassment, impersonation and underage concern
(`…20260101000100_extensions_and_enums.sql:27-34`;
`…20260811000300_report_category_post_image.sql:4`), triaged manually
(`docs/MODERATION.md:150-169`). Preventive controls are structural rather than analytical: no public
surface, no DM or anonymous-chat surface, friends-only distribution, blocks, per-action rate limits,
and server-side control-character sanitisation of post and comment text
(`…20260811000100_feed_tables.sql:12-28`).

**Why reactive is the appropriate design here, stated explicitly as the justification.** Content is
only ever distributed to people the author has mutually accepted as friends
(`…20260811000500_rpc_feed_posts.sql:160`), so there is no stranger-facing surface and no
viral-amplification path — the population exposed to any given item is small, known to the author, and
able to report it. Proactive scanning of that content would mean submitting every private photo and
every private post body to an automated classifier, which is itself a substantial and continuous
processing operation over sensitive material, arguably requiring its own Art. 9 and Art. 22 analysis,
and in most implementations a transfer to a third-party service — precisely the kind of processing
this app otherwise avoids entirely (no third-party SDKs at all, `project.yml:26-28,53-55`).
Proportionality under Art. 5(1)(c) therefore favours the narrower control. This is a reasoned choice,
not an omission.

**Residual.** Harmful content is visible to the author's friends until someone reports it and a
moderator acts; a small closed group is also where a victim may be least willing to report, since
reporting is not anonymous to the operator and the parties know each other. There is no service-level
response-time commitment. A post's own author cannot remove another user's abusive comment on their
post — only delete the whole post or report the comment (`docs/MODERATION.md:44-55`). And an
administratively disabled profile can still write: the disable is a `profiles.deleted_at` update that
hides the account from every read path but leaves its JWT valid, and no write path re-checks the
caller's own `deleted_at` (`docs/MODERATION.md:155-163`). **Residual risk: moderate likelihood,
moderate-to-high severity, accepted with the justification above.** `[[Operator decision: target
triage turnaround, and who performs it.]]`

### 3.7 Risk 7 — account deletion erases the moderation record about the deleted user

**What the system does.** `reports.reporter_id` and `reports.reported_user_id` both cascade from
`profiles` (`…20260101000300_social_tables.sql:54-55`), and `profiles` cascades from `auth.users`
(`…20260101000200_core_tables.sql:7`). The `delete-account` Edge Function deletes the auth user
(`supabase/functions/delete-account/index.ts:69`). Therefore deleting an account destroys every
report filed **by** that user and every report filed **about** them, immediately and irreversibly.

**Risk.** Two distinct harms. First, to *other* data subjects: a user who reported harassment loses
their report, and the safety history that justified retaining it under Art. 6(1)(f) is gone. Second,
to the integrity of the safety process: a user who has been reported can erase the reports about them
by exercising their Art. 17 right, and could then return under a new account with no trace. Third, it
contradicts what users are told — `docs/legal/ACCOUNT_DELETION_POLICY.md:29` says reports "may be
retained (anonymised where possible)", and `purge_resolved_reports` implements an 18-month clock
(`…20260812000400_retention_purges.sql:95-114`) that the cascade pre-empts.

**Assessment.** This needs a deliberate decision, not a silent cascade. Retaining a report about a
departed user beyond their erasure request requires an Art. 17(3) justification and, if kept, the
`reported_user_id` reference would need to be severed or pseudonymised rather than left pointing at a
deleted row. **Residual risk: moderate likelihood, moderate severity, unmitigated and
undocumented-until-now.** `[[Operator + counsel decision: whether reports survive deletion, in what
form, and for how long.]]`

### 3.8 Risk 8 — published retention periods are not enforced, so data is kept indefinitely

Four purge functions exist and are correct — `purge_soft_deleted_posts`,
`purge_soft_deleted_comments`, `purge_soft_deleted_pint_entries`, `purge_resolved_reports`
(`…20260812000400_retention_purges.sql:20-114`) — as does `prune_rate_limit_events`
(`…20260101000600_security_helpers.sql:130-137`) and the `storage-gc` drain
(`supabase/functions/storage-gc/index.ts`). **None of them is scheduled.** There is no `pg_cron` job
and no scheduler configuration anywhere in the repository; only unchecked pre-launch checklist items
(`docs/RELEASE_CHECKLIST.md:12-20`). All are revoked from `authenticated`
(`…20260812000400:119-122`), so no user action triggers them either.

Consequences today: a user who deletes a post or undoes a drink entry has hidden it, not removed it —
`deleted_at` is set and the row and its photo bytes remain indefinitely; resolved reports are kept
without limit; `rate_limit_events` accumulates a per-user, per-second action log forever. Additional
categories have no purge function at all, so they are unbounded by design rather than by omission:
`nudges`, and `storage_gc_queue`, whose rows are marked processed but never deleted
(`…20260812000200_storage_gc_queue.sql:55-64`) while `object_path` embeds the owner's uuid.
Unresolved reports (`open`, `reviewing`) are outside `purge_resolved_reports`'s predicate
(`…20260812000400:106-107`) and so are also unbounded.

**Residual risk: certain likelihood while unscheduled, moderate severity — a straightforward Art.
5(1)(e) storage-limitation failure, and the gap between what `docs/legal/DATA_RETENTION_POLICY.md`
publishes and what happens.** Scheduling is an operator action, not a code change; §4.5 lists it as a
launch blocker.

### 3.9 Risk 9 — access-rights gaps

- **The self-service export has no client entry point.** `export_my_data()` is implemented, scoped to
  `auth.uid()` in every subquery, capped at 10,000 rows per collection with a `truncated` flag, and
  granted to `authenticated` (`…20260812000500_export_my_data.sql:81-403,402-403`). No Swift code
  calls it. Meanwhile `docs/PRIVACY.md:36-37` and `docs/legal/PRIVACY_POLICY.md:65` tell users
  in-app export is available. Until a screen ships, Art. 15/20 requests must be served manually and
  those two statements are inaccurate.
- **Nudges the user sent are readable by no path in the app.** `public.nudges` is revoked with no
  policies (`…20260803000000_nudges.sql:25-26`) and `get_received_nudges()` reads only the inbound
  side (`…20260803000000:107`). The `nudges_sent` collection in `export_my_data()`
  (`…20260812000500:343-357`) is the only read path anywhere — and per the preceding bullet, nothing
  invokes it. A user cannot currently obtain a record of the Nudges they sent.
- **`rate_limit_events` is not exported at all**, although it is personal data about the subject
  (§4.11 of the records). Arguably in scope for Art. 15.
- **No process exists for rectification, restriction or objection requests** beyond direct profile
  DML; the process itself is an open checklist item (`docs/RELEASE_CHECKLIST.md:55`).

**Residual risk: certain likelihood, low-to-moderate severity, straightforwardly fixable.**

### 3.10 Risk 10 — one user's deletion erases another user's content

When `purge_soft_deleted_posts` hard-deletes an aged, soft-deleted post, FK cascades take every
comment and cheer on it (`…20260811000100_feed_tables.sql:59,70`). So if B comments on A's post and A
deletes the post, B's comment — which B never deleted and which has no retention clock of its own — is
destroyed when A's post is purged. This is deliberate and reasoned in the migration itself
(`…20260812000400_retention_purges.sql:9-18`) and disclosed to users
(`docs/legal/DATA_RETENTION_POLICY.md:26-32`): a comment has no surface to appear on once its post is
gone. It is nonetheless one data subject's personal data being erased as a side effect of another's
action. **Residual risk: high likelihood, low severity, accepted and documented.**

### 3.11 Risk 11 — profile text and pub suggestions are not validated server-side

There is no profile-update RPC. `profiles_update_self` permits direct DML with only an ownership check
(`…20260101000700_rls_policies.sql:34-37`), so the sanitisation of `display_name`, `bio` and `city` —
and the reserved-word username check — live in the client
(`CheekyPint/Features/Settings/EditProfileView.swift:137-139`; `docs/MODERATION.md:109-123`) and are
bypassable by anything that calls the API directly. Database `check` constraints still bound length
and username character set (`…20260101000200_core_tables.sql:9-19`), so the exposure is
impersonation and display-spoofing text (bidi overrides, zero-width characters, a claimed `admin`
username), not unbounded input. Separately, `pubs` inserts are direct RLS-governed DML with no rate
limit and no sanitiser, and `formatted_address` has no length cap
(`…20260101000400_pub_tables.sql:6-21`; `…20260101000700_rls_policies.sql:84-85`) — a spam and
abusive-content vector into a table every authenticated user can read
(`…20260101000700_rls_policies.sql:82-83`). Feed post and comment text, by contrast, *is* sanitised
in the database (`…20260811000100_feed_tables.sql:12-28`). **Residual risk: moderate likelihood, low
severity for privacy, moderate for impersonation.**

### 3.12 Risk 12 — age assurance is self-declaration only

`legal_age_confirmed_at` is a timestamp the client sets by direct profile update
(`CheekyPint/Core/Database/ProfileRepository.swift:80-83`;
`…20260101000200_core_tables.sql:20,29`). Nothing verifies it, and because the write is direct DML it
could be set without any UI ever showing a prompt. A minor can therefore hold an account, and their
drink diary — the most sensitive data the app holds — would be processed on a basis that assumes
adulthood. The compensating controls are the 17+ store rating
(`docs/RELEASE_CHECKLIST.md:47`), the `underage_concern` report category
(`…20260101000100_extensions_and_enums.sql:32`) and manual triage. **Residual risk: moderate
likelihood, high severity where it occurs.** `[[Operator decision: whether self-declaration is
defensible for this content, or whether stronger age assurance is required — note this interacts with
§3.1: if the diary is Art. 9 data, a minor's diary is special-category data about a child.]]`

### 3.13 Risk 13 — third-country transfer status is undetermined

No Supabase project region has been chosen (`docs/RELEASE_CHECKLIST.md:5`), so it cannot presently be
stated whether personal data will leave the EEA, which Art. 46 mechanism applies, or which
sub-processors are involved. Every transfer statement in
[RECORDS_OF_PROCESSING.md §6](RECORDS_OF_PROCESSING.md#6-transfers-to-third-countries-art-301e) and in
`docs/legal/PRIVACY_POLICY.md:52-55` is a placeholder. Publishing a privacy policy that asserts
anything about transfers before the region is fixed would be a false statement to data subjects.
**Residual risk: cannot be assessed until the region is chosen; blocks launch.**

### 3.14 Risk 14 — blocks and reports are invisible to the person they concern

A blocked user is never told they were blocked (`blocks` is readable only by the blocker,
`…20260101000700_rls_policies.sql:68-69`), and a reported user is never told a report exists
(`reports` is readable only by the reporter, `…20260101000700:74-75`). Both are deliberate and
necessary safety properties — telling someone they were blocked or reported is a retaliation vector.
Both are also processing of that person's personal data, including up to 1,000 characters of free
text written about them (`…20260101000300_social_tables.sql:57`), that is withheld from them.
Art. 15 does not permit blanket withholding; the restriction has to rest on Art. 15(4) or a
§ DSG-based restriction, applied per request rather than as an architectural default. **Residual
risk: certain likelihood, low-to-moderate severity.** `[[Counsel question: on what basis are report
contents withheld from the reported person when they make an access request, and is a redacted
disclosure required?]]`

### 3.15 Risk 15 — breach detection and response

The service-role key is confined to Edge Function environments
(`supabase/functions/delete-account/index.ts:12`; `supabase/functions/storage-gc/index.ts:49-51`) and
its compromise would expose everything in §2.2. No breach-detection, logging-review, or Art. 33/34
notification procedure is documented anywhere in the repository, and there is no audit log of
moderator or service-role actions (`docs/MODERATION.md:163` lists an audit log as a fast-follow).
**Residual risk: low likelihood, very high severity, procedurally unmitigated.**
`[[Operator: Art. 33 procedure, 72-hour notification path, and who holds it.]]`

## 4. Measures to address the risks (Art. 35(7)(d))

### 4.1 Shipped measures, mapped to risks

| Measure | Evidence | Addresses |
|---|---|---|
| No public surface; visibility ceiling is "accepted friends", with no `public` enum value | `…20260101000100_extensions_and_enums.sql:10-12` | 3.2, 3.4, 3.6 |
| Deny-by-default: RLS with no policies on all feed tables, `nudges`, `rate_limit_events`, `storage_gc_queue`; all privileges revoked | `…20260811000100_feed_tables.sql:93-101`; `…20260803000000_nudges.sql:25-26`; `…20260101000700_rls_policies.sql:147`; `…20260812000200_storage_gc_queue.sql:25-26` | 3.3, 3.4 |
| Self-only RLS on every directly-readable table; raw diary entries readable by their owner alone | `…20260101000700_rls_policies.sql:26-142`, esp. `:135-136` | 3.1, 3.3 |
| Friends-only enforcement re-derived per call, block-aware in both directions | `…20260101000600_security_helpers.sql:10-22,26-41`; `…20260811000500_rpc_feed_posts.sql:160`; `…20260811000600_rpc_feed_social.sql:5-19,204` | 3.2, 3.4, 3.6 |
| Photo bytes access-controlled by the friend graph, not by filename obscurity | `…20260812000100_private_post_images.sql:14,36-50,67-72` | 3.2, 3.5(a) |
| Relationship oracles no longer client-callable | `…20260812000600_revoke_helper_oracles.sql:20-23` | 3.4 |
| Field-level privacy applied inside RPCs; totals degrade to a private marker, never a fake zero | `…20260101000800_rpc_social.sql:247,315-317,379-390` | 3.1, 3.4 |
| `city_visibility` and `favourite_pubs_visibility` default to off | `…20260101000200_core_tables.sql:44,49` | 3.3 |
| Precise location never stored; When-In-Use only; no background location | `CheekyPint/Core/Location/LocationService.swift:22,28` | 3.3 |
| Storage writes confined to the caller's own folder; path-traversal rejected before the ownership check | `…20260101000950_storage.sql:17-31`; `…20260811000200_feed_storage.sql:16-30`; `…20260811000500_rpc_feed_posts.sql:42-55` | 3.2, 3.5 |
| Invite tokens stored as SHA-256 only; uniform failure messages; resolution rate-limited | `…20260101000800_rpc_social.sql:27-31,53,63-68` | 3.4 |
| Per-action rate limits on 15 actions, including `data_export` at 5/24 h | `…20260101000600_security_helpers.sql:100-127`; caps enumerated in [RECORDS_OF_PROCESSING.md §8.5](RECORDS_OF_PROCESSING.md#85-abuse-limits) | 3.6, 3.11 |
| Server-side sanitisation of post and comment text | `…20260811000100_feed_tables.sql:12-28`, applied at `…20260811000500:26-30` and `…20260811000600:88` | 3.11 |
| @-mentions restricted to the commenter's own friends; a mention that would leak a third party's hidden relationship is dropped silently rather than rejected distinguishably | `…20260811000600_rpc_feed_social.sql:106-114` | 3.4, 3.6 |
| Reporting for accounts, posts and comments into one queue | `…20260101000800_rpc_social.sql:204-228`; `…20260811000700_rpc_feed_reports.sql:4-76` | 3.2, 3.6 |
| Erasure spans database, both storage buckets and the auth user, aborting before auth deletion if storage cleanup fails so the request stays retryable; the app invokes the Edge Function rather than the bare RPC, pinned by a regression test | `…20260101000850_rpc_pints_sessions.sql:254-284`; `supabase/functions/delete-account/index.ts:45-70`; `CheekyPint/Core/Database/ProfileRepository.swift:98-101`; `CheekyPintTests/DeleteAccountWiringTests.swift:52-61` | 3.5, 3.8 |
| Deferred byte deletion: the path is captured in the same statement that soft-deletes the post, because the row is its only record | `…20260812000300_enqueue_deleted_post_images.sql:44-48`; drained by `supabase/functions/storage-gc/index.ts:57-100` | 3.5, 3.8 |
| Self-service export scoped to `auth.uid()` in every subquery, bounded at 10,000 rows per collection with a `truncated` flag, live credentials excluded | `…20260812000500_export_my_data.sql:81-403`, cap `:89`, exclusions `:63-72` | 3.9 |
| Never celebrates heavy or rapid drinking: confirmation tone is replaced by a neutral welfare message when entries cluster, computed on device and stored nowhere | `CheekyPintCore/…/WelfareMonitor.swift:11-45` | Welfare (not a GDPR risk, recorded for completeness) |
| No third-party SDKs; analytics a no-op with a nine-event, no-personal-data allowlist | `project.yml:26-28,53-55`; `CheekyPint/Core/Analytics/AnalyticsService.swift:6-29` | 3.6, 3.13 |
| Service-role key confined to Edge Function environments; `storage-gc` requires the key itself, not merely a user JWT | `supabase/functions/delete-account/index.ts:12`; `supabase/functions/storage-gc/index.ts:49-51` | 3.15 |
| Automated verification of allowed and denied paths across RLS and every RPC | `supabase/tests/rls_rpc_suite.sql` via `supabase/tests/run_local_pg.sh` — 87 checks pass on this revision | all technical |

### 4.2 Measures required before launch — legal

| # | Action | Risk |
|---|---|---|
| L1 | **Obtain qualified Austrian legal advice on the Art. 9 classification of the drink diary**, and implement whatever follows: lawful basis, explicit-consent flow and withdrawal path if required, DPO reassessment, corrections to `docs/legal/PRIVACY_POLICY.md:28` and `docs/APP_PRIVACY_DATA_MAPPING.md:31` | 3.1 |
| L2 | Review of all `docs/legal/*` templates and completion of every `[[placeholder]]` | 3.13, all |
| L3 | Decide whether moderation reports survive account deletion, in what form, and record the Art. 17(3) basis | 3.7 |
| L4 | Decide the basis for withholding report contents from a reported data subject who makes an access request | 3.14 |
| L5 | Choose the Supabase region, execute and reference the Art. 28 DPA, and complete the transfer section | 3.13 |
| L6 | Assess whether self-declared age is defensible for this content | 3.12 |
| L7 | Document the Art. 33/34 breach procedure and moderator access arrangements | 3.15, 3.6 |

### 4.3 Measures required before launch — operational

| # | Action | Risk |
|---|---|---|
| O1 | **Schedule every retention job** — `prune_rate_limit_events`, `purge_soft_deleted_posts`, `purge_soft_deleted_comments`, `purge_soft_deleted_pint_entries`, `purge_resolved_reports`, and the `storage-gc` drain (`docs/RELEASE_CHECKLIST.md:12-20`). Until this is done the published retention policy is not met | 3.8 |
| O2 | Monitor `storage_gc_queue` for `attempts > 3` or a non-null `last_error` (`docs/RELEASE_CHECKLIST.md:22-23`) | 3.8 |
| O3 | Define and staff moderation triage, with a target turnaround for `underage_concern` and harassment | 3.6, 3.12 |
| O4 | Establish the data-subject request process for the rights the app cannot self-serve (`docs/RELEASE_CHECKLIST.md:55`) | 3.9, 3.14 |

### 4.4 Measures recommended before launch — technical

| # | Action | Risk |
|---|---|---|
| T1 | Make `avatars` a private bucket with a visibility-aware read policy, mirroring `…20260812000100_private_post_images.sql` | 3.5(b) |
| T2 | Ship the export screen so Art. 15/20 is genuinely self-service, and correct `docs/PRIVACY.md:36-37` / `docs/legal/PRIVACY_POLICY.md:65` until it exists | 3.9 |
| T3 | Give the user a read path for Nudges they sent | 3.9 |
| T4 | Add a retention limit for `storage_gc_queue`, `nudges`, and unresolved reports | 3.8 |
| T5 | Move profile-text sanitisation and the username reserved-word check server-side, behind an RPC | 3.11 |
| T6 | Rate-limit and sanitise `pubs` inserts; cap `formatted_address` | 3.11 |
| T7 | Have write paths re-check the caller's own `profiles.deleted_at`, so an administratively disabled account cannot keep posting (`docs/MODERATION.md:155-163`) | 3.6 |
| T8 | Refresh the three stale documents: `docs/MODERATION.md:57-70` and `docs/PRIVACY.md:43-51` still describe `post-images` as public; `docs/SECURITY.md:27-30` still describes the relationship helpers as client-executable | accuracy |
| T9 | Consider an upload-time reminder about photographing other people | 3.2 |
| T10 | Consider stating on the privacy-settings screen that hiding a total does not hide participation | 3.4 |

## 5. Necessity and proportionality (Art. 35(7)(b))

| Principle | Assessment |
|---|---|
| **Lawfulness (Art. 5(1)(a))** | **Cannot be concluded.** Depends entirely on §3.1. The legal bases in `docs/legal/PRIVACY_POLICY.md:32-37` are an unreviewed template, and if the diary is Art. 9 data the contract basis for the diary is insufficient on its own. |
| **Purpose limitation (5(1)(b))** | Good. Each table maps to one product purpose (see [RECORDS_OF_PROCESSING.md §2](RECORDS_OF_PROCESSING.md#2-purposes-of-processing-art-301b)); no secondary use, no profiling for advertising, no data sales, and no third-party recipient beyond the hosting processor. |
| **Data minimisation (5(1)(c))** | Largely good, with named exceptions. Every sensitive field is optional: `volume_ml`, `pub_id`, `session_id`, `private_note`, `place_label`, photos, `city`, `bio`, `username`, `avatar_path`. Serving type is an enum rather than free text. No precise location is stored. Exceptions worth an operator decision: `rate_limit_events` retains a per-user, per-second action log for abuse control (proportionate, but see 3.8 on its unenforced 2-day limit); `flagged_high_frequency` is a stored inference that is never shown to anyone and whose necessity is unclear; and `pubs.formatted_address` has no length cap. |
| **Accuracy (5(1)(d))** | Adequate. `occurred_at` is user-correctable, `created_at` is server-authoritative, future timestamps beyond a 5-minute skew are rejected (`…20260101000850_rpc_pints_sessions.sql:47-51`), and idempotency keys prevent duplicate entries (`…20260101000500:34`). |
| **Storage limitation (5(1)(e))** | **Failing in practice.** The functions exist; nothing schedules them (§3.8). Several categories have no retention limit at all. |
| **Integrity and confidentiality (5(1)(f))** | Strong in the database layer (§4.1). Two named weaknesses: the public `avatars` bucket (3.5(b)) and client-only profile sanitisation (3.11). |
| **Accountability (5(2))** | Improving. This document and [RECORDS_OF_PROCESSING.md](RECORDS_OF_PROCESSING.md) are the first Art. 30/35 artefacts; a test suite evidences the technical claims; no organisational documentation exists yet (3.15). |
| **Proportionality of the friends-only design** | The processing is what the service is: a diary that records nothing cannot be a diary. The distribution ceiling is set at the narrowest level that still delivers the social feature, and is enforced server-side rather than in the client. Where a less intrusive alternative exists and was not taken, it is listed in §4.4. |

## 6. Consultation

| Consultation | Status |
|---|---|
| DPO advice (Art. 35(2)) | `[[no DPO appointed; Art. 37 assessment not yet performed — and its outcome may depend on §3.1]]` |
| Views of data subjects (Art. 35(9)) | `[[not sought]]` |
| Processor input (Supabase) | `[[not sought; DPA not yet executed]]` |
| Prior consultation with the Datenschutzbehörde (Art. 36) | `[[not required unless residual high risk remains after §4 — assess once §3.1 is answered]]` |

## 7. Residual risk register

Severity is from the data subject's perspective. "After §4" means after the launch measures in §4.2,
§4.3 and §4.4 are complete.

| # | Risk | Now | After §4 | Mitigable further? |
|---|---|---|---|---|
| 3.1 | Art. 9 classification of the diary | **Unassessable until answered** | Depends on the answer | No — requires legal advice (L1) |
| 3.2 | Third parties in photographs | High likelihood, moderate-high severity | Moderate | Only partially; no consent mechanism is possible for an unidentifiable bystander |
| 3.3 | Movement-and-consumption profile | Moderate likelihood, high severity | Moderate | Partly, via retention limits |
| 3.4 | Re-identification via the friend graph | High likelihood, low-moderate severity | Low-moderate | Inherent to a social feature; transparency is the remedy |
| 3.5(a) | Copies already fetched cannot be recalled | Certain, moderate | Unchanged | **No** — inherent to sharing an image |
| 3.5(b) | Public `avatars` bucket | Moderate likelihood, moderate-high severity | **Eliminated by T1** | Yes |
| 3.6 | Reactive-only moderation | Moderate likelihood, moderate-high severity | Moderate | Accepted with the §3.6 justification |
| 3.7 | Reports erased by account deletion | Moderate, moderate | Decided by L3 | Yes |
| 3.8 | Retention not enforced | Certain, moderate | **Eliminated by O1 + T4** | Yes |
| 3.9 | Access-rights gaps | Certain, low-moderate | **Eliminated by T2 + T3** | Yes |
| 3.10 | Cross-user erasure of comments | High, low | Unchanged — accepted and disclosed | Only by retaining orphaned content, which is worse |
| 3.11 | Client-only sanitisation; unconstrained `pubs` | Moderate, low-moderate | Low | Yes (T5, T6) |
| 3.12 | Self-declared age | Moderate, high where it occurs | Depends on L6 | Partly |
| 3.13 | Transfer status undetermined | Unassessable | Resolved by L5 | Yes |
| 3.14 | Blocks/reports withheld from the person concerned | Certain, low-moderate | Depends on L4 | Procedural |
| 3.15 | Breach detection and response | Low likelihood, very high severity | Reduced by L7 | Procedurally |

## 8. Decision and sign-off

**Left deliberately blank for the operator.** This section must not be completed by anyone who has
not read §3.1 and obtained the advice required by L1. In particular, do not record an outcome of
"proceed" while the Art. 9 question is open — the residual risk in row 3.1 above is not assessable
until it is answered, and Art. 36(1) prior consultation may be triggered by the answer.

| Field | Value |
|---|---|
| Assessment performed by | `[[name, role, date]]` |
| DPO advice sought and recorded | `[[yes/no — advice, date]]` |
| Legal review of §3.1 obtained | `[[firm/counsel, date, conclusion]]` |
| Residual risk accepted / not accepted | `[[decision]]` |
| Art. 36 prior consultation required? | `[[determination + reasoning]]` |
| Conditions attached to the decision | `[[e.g. launch blocked until O1, T1, T2 complete]]` |
| Approved by (controller) | `[[name, role, signature, date]]` |
| Next review date | `[[date]]` |

## 9. Review triggers

Re-run this assessment when any of the following occurs, and re-verify every citation against the
migrations at the same time:

- counsel answers the Art. 9 question (§3.1);
- the feed client surface ships, or any new sharing surface, notification channel, or wider-than-
  friends visibility is added;
- the `avatars` bucket changes, or any storage policy changes;
- a third-party SDK, analytics sink, crash reporter, or push provider is introduced;
- the Supabase region or processor set changes;
- proactive content scanning is introduced (which is itself new processing needing its own
  assessment — §3.6);
- retention periods or purge behaviour change;
- a personal-data breach occurs;
- at minimum annually.

---

Maintained alongside [RECORDS_OF_PROCESSING.md](RECORDS_OF_PROCESSING.md). Both are cross-checked
against `supabase/migrations/` on every schema change; a claim in either document that no longer
matches the code is a defect in the document.
