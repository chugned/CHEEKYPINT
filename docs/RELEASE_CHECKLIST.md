# Release checklist

## Backend

- [ ] `supabase link` to the target project; `supabase db push` migrations
- [ ] `supabase functions deploy delete-account`; set `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_URL`,
      `SUPABASE_ANON_KEY` function secrets
- [ ] Configure Auth: enable Sign in with Apple (Services ID, key, team id) + email OTP; set
      Site URL + redirect URLs (`cheekypint://auth-callback`, `https://cheekypint.app/auth-callback`)
- [ ] Create the `avatars` storage bucket (migration does this) and confirm policies
- [ ] Schedule any leaderboard cache jobs if added
- [ ] Schedule the retention jobs `docs/legal/DATA_RETENTION_POLICY.md` commits to — without
      these running, that document is aspirational, not enforced:
      - `prune_rate_limit_events` — daily
      - `purge_soft_deleted_posts` — daily
      - `purge_soft_deleted_comments` — daily
      - `purge_soft_deleted_pint_entries` — daily
      - `purge_resolved_reports` — weekly. Two clocks, both defaulted: 18 months after
        `reviewed_at` for resolved reports (the mid-point of the published 12–24 month window), and
        24 months after `created_at` for reports retained past deletion of their subject and never
        resolved. Call it with no arguments to take both defaults. **Both numbers need counsel
        sign-off** (`docs/legal/DATA_RETENTION_POLICY.md`)
      - `storage-gc` Edge Function (drains `storage_gc_queue`) — hourly
- [ ] Verify RLS suite against a staging DB: `supabase/tests/run_local_pg.sh`
- [ ] Monitor `storage_gc_queue` for rows with `attempts > 3` or a non-null `last_error` — a stuck
      drain (e.g. a rotated service-role key) is otherwise invisible

## Moderation

- [ ] Read [MODERATION_PROCESS.md](MODERATION_PROCESS.md) — the runbook for `public.reports`: what
      each status means, the SQL to transition a report (`public.review_report`) and to enforce a
      takedown, per-category handling, and how the queue satisfies App Store Review guideline 1.2's
      "timely response" limb. Without a person working that queue, the reporting mechanism is a
      write-only inbox and 1.2 is not met
- [ ] Commit to the triage target in its §9 (queue checked every 48 hours; same day for
      `underage_concern` and `impersonation`) or change the number in that document to one that will
      actually be met. It is deliberately not published to users as a promise
- [ ] Replace the `support@cheekypint.app` placeholder with a live, monitored address — guideline 1.2
      requires published contact information
- [ ] Note the consequence of the §8 decision (reports filed by a departing user are retained, with
      their free text erased): a queue read can contain reports with no reporter to follow up with and
      no description, so for an **account-level** report there may be nothing left to adjudicate on.
      `dismissed` is the honest outcome for those. Counsel should confirm that trade-off, not just the
      retention periods

## App configuration

- [ ] Set `SUPABASE_URL` + `SUPABASE_ANON_KEY` in `Staging.xcconfig` / `Production.xcconfig`
- [ ] Bundle ids, `DEVELOPMENT_TEAM`, signing (Automatic or profiles)
- [ ] Host `apple-app-site-association` at `https://cheekypint.app/.well-known/`
- [ ] Confirm URL scheme + associated domains match entitlements

## Quality gates

- [ ] `cd CheekyPintCore && swift test` (or `swift run corecheck`) green
- [ ] App unit + UI tests green in Xcode
- [ ] Accessibility pass: VoiceOver on Home/log/undo/leaderboard; Dynamic Type XXL; Reduce Motion;
      contrast; 44pt targets
- [ ] Error/empty/offline/permission-denied states verified on each screen
- [ ] IPv6-only network test (App Review requirement)
- [ ] Crash-free smoke on a physical device + TestFlight

## Store

- [ ] Metadata, keywords, categories ([APP_STORE_SUBMISSION.md](APP_STORE_SUBMISSION.md))
- [ ] 1024 icon + screenshots per the storyboard
- [ ] App Privacy questionnaire matches [APP_PRIVACY_DATA_MAPPING.md](APP_PRIVACY_DATA_MAPPING.md)
- [ ] Age rating (17+/alcohol), export compliance, review notes + demo account
- [ ] Privacy Policy / Terms / Guidelines URLs live and reviewed by counsel

## Legal (before production launch)

- [ ] All `docs/legal/*` templates reviewed by a qualified professional
- [ ] Operator entity, address, DPO/contact, and processor/region details filled in
- [ ] GDPR data-subject request process in place
- [ ] **Art. 9 question resolved by qualified Austrian counsel** — whether the drink diary is
      special-category health data ([DPIA.md](DPIA.md) §3.1). It is deliberately left unresolved in
      that document. It must be answered **before launch**, because the answer determines the lawful
      basis for the diary, whether explicit consent under Art. 9(2)(a) is required (nothing in the
      app implements such a flow today), whether a DPIA is mandatory rather than prudent, whether a
      DPO must be appointed, and whether `docs/legal/PRIVACY_POLICY.md:28` and
      `docs/APP_PRIVACY_DATA_MAPPING.md:31` — which both state that no health data is collected —
      are accurate
- [ ] [DPIA.md](DPIA.md) (Art. 35) reviewed; every measure in its §4.2 (legal), §4.3 (operational)
      and §4.4 (technical) closed or explicitly accepted; §8 decision and sign-off completed by the
      controller. Do not record "proceed" while §3.1 is open
- [ ] [RECORDS_OF_PROCESSING.md](RECORDS_OF_PROCESSING.md) (Art. 30) completed — controller identity,
      Supabase region, Art. 28 DPA reference, transfer mechanism — and its §9 gap list reviewed. Both
      documents cite the migrations by `file:line`; re-verify them against `supabase/migrations/`
      whenever the schema changes
