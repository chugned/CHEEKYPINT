# Moderation process — how reports actually get handled

This is the operational runbook for `public.reports`. [MODERATION.md](MODERATION.md) describes the
controls that exist in the product; this document describes what a human does with a report once it
arrives, and how.

> **Who "the operator" is.** One person: the Supabase project owner. There is no moderation team, no
> moderator role in the database, no rota, and no ticketing system. Everything below is done by hand
> in the Supabase dashboard SQL editor. This document deliberately does not describe a service-level
> agreement, because none has been agreed and inventing one would be worse than admitting there
> isn't one. What it does describe is a repeatable procedure and a target the operator can actually
> meet alone.

## 1. Statuses, and what each one commits you to

`public.report_status` has four values (`…20260101000100_extensions_and_enums.sql:36`).

| Status | Meaning | `reviewed_at` | Retention effect |
|---|---|---|---|
| `open` | Filed by a user. Nobody has looked at it. The only state a report can be created in. | NULL | None yet. A report about a **live** account that stays `open` is kept indefinitely — there is no purge for it, deliberately (see §7) |
| `reviewing` | The operator has picked it up and is deciding. Use it when you stop mid-triage, so a later pass can tell "not yet looked at" from "in progress". | NULL — cleared if it was set | Clock stopped |
| `actioned` | Reviewed, and the operator did something: took content down, disabled an account, or contacted someone. | Stamped | 18-month clock starts |
| `dismissed` | Reviewed, and no action was warranted. This is a real outcome, not a way to clear the queue. | Stamped | 18-month clock starts |

Two things follow from the table and are enforced by the database, not by convention:

- **`reviewing` does not stamp `reviewed_at`, and clears it if it was already set.** `reviewed_at` is
  the retention clock's zero point, and `reviewing` means the review *started*, not that it
  concluded. If `reviewing` stamped it, a report that took three months to resolve would be
  destroyed 15 months after its resolution instead of 18 — quietly shortening the published
  retention period in the direction that loses evidence. The cost of this choice is that "when did
  triage start" is recorded nowhere.
- **A resolved report always has a `reviewed_at`, and an unresolved one never does.** This is a CHECK
  constraint (`report_reviewed_at_matches_status`), so a hand-typed
  `update reports set status = 'actioned'` **fails** rather than creating a report that is resolved
  but invisible to the retention purge. That state — resolved with a NULL `reviewed_at`, therefore
  never purged — is the state the entire queue was in before `review_report` existed, and the
  constraint exists so it cannot come back.

There is no `reviewed_by` column: with a single operator it would only ever hold one value. If a
second reviewer is ever added, that column has to be added at the same time or the audit trail is
worthless.

## 2. Reading the queue

Reports are readable in the Supabase dashboard because you are the project owner there, and RLS does
not constrain the owner. The only RLS policy on the table is `reports_select_own`
(`…20260101000700_rls_policies.sql:74`), which lets a **reporter** read their own filed reports and
nothing else. There is no admin-read RPC on purpose: adding one would create a privileged read path
that then has to be defended, and the dashboard already works.

Oldest first, with the two categories that warrant jumping the queue pulled to the top:

```sql
select id, status, category, created_at,
       reported_user_id, reported_user_key, post_id, comment_id, details
  from public.reports
 where status in ('open', 'reviewing')
 order by case category
            when 'underage_concern' then 0
            when 'impersonation'    then 1
            else 2
          end,
          created_at
 limit 50;
```

Context on the same subject before you decide (a second report about the same account often changes
the answer):

```sql
-- while the account still exists
select id, category, status, created_at, details
  from public.reports
 where reported_user_id = '<subject-uuid>'::uuid
 order by created_at desc;
```

## 3. Transitioning a report

`public.review_report(report_id, target_status)` is the only supported way to change a report's
state. Paste into the dashboard SQL editor:

```sql
-- pick it up
select public.review_report('00000000-0000-0000-0000-000000000000'::uuid, 'reviewing');

-- resolve it, one of:
select public.review_report('00000000-0000-0000-0000-000000000000'::uuid, 'actioned');
select public.review_report('00000000-0000-0000-0000-000000000000'::uuid, 'dismissed');
```

It returns the transition so you can paste the result into your notes:

```json
{"status": "actioned", "report_id": "…", "reviewed_at": "2026-08-13T09:12:44.51+00:00",
 "previous_status": "reviewing"}
```

Behaviour worth knowing before you need it:

- **`open` is rejected.** `review_report(id, 'open')` raises
  `review_report: open is a report's initial state, not a review outcome`. To park something you
  have looked at but cannot resolve, use `reviewing`.
- **A wrong id is rejected loudly**, with the id echoed back:
  `review_report: no report with id <uuid>`. It does not silently affect zero rows.
- **Re-running the same outcome is safe.** It does not restart the 18-month retention clock.
  Changing the outcome (`actioned` → `dismissed`) does re-stamp, because that is a new conclusion.
- **It is service-role only.** `authenticated` and `anon` have no EXECUTE privilege; a client call is
  refused with `42501`. In the dashboard you are the table owner, so no grant is involved. A
  scheduled or service-key invocation uses the explicit `service_role` grant.
- **`review_report` records a decision. It does not carry it out.** Nothing is taken down, hidden, or
  disabled as a side effect. Enforcement is §5, done separately and deliberately.

## 4. What to do per category

Every row below is a default, not a rule; the details text usually decides. "Take down" means §5.

| Category | Default handling |
|---|---|
| `underage_concern` | **Triage first, ahead of everything else.** The app is 17+ and alcohol-related. If the profile or content supports the concern, disable the account (§5) *before* finishing the review, then `actioned`. If it looks like a grudge report with nothing behind it, `dismissed` — do not disable an account on an unsupported claim. |
| `impersonation` | Triage second. Compare the profile against the claim; check `username` and `display_name` against the impersonated party. Server-side there is **no** reserved-word protection (`docs/MODERATION.md` — `UsernameValidator` is client-side only and `profiles_update_self` permits direct DML), so `admin`/`support`-style usernames are genuinely claimable and this category is not theoretical. Rename or disable, then `actioned`. |
| `harassment` | Read `details` and the linked content. The feed is friends-only, so both parties know each other and the reporter may be at risk of retaliation: never disclose to the subject that a report was filed. Remind the reporter (out of band) that **Block** is immediate and does not wait for you. Take the content down and/or disable, then `actioned`. |
| `inappropriate_text` | Judge against [COMMUNITY_GUIDELINES.md](legal/COMMUNITY_GUIDELINES.md). Take down the specific post/comment rather than the account for a first instance. |
| `inappropriate_post_image` | Same, for a photo. **Take the photo down via §5 so the storage object is queued for deletion** — soft-deleting the row alone leaves the bytes fetchable to anyone holding the URL. |
| `inappropriate_profile_image` | Clear `profiles.avatar_path` (§5). The object in the `avatars` bucket needs removing too; the same URL-already-escaped caveat applies. |
| `other` | Read it. Most of these are support requests, not moderation. Answer the person if there is an address to answer, then `dismissed` with the reason in your notes. |

For every category: if the report concerns you personally or a friend, you are not a neutral
reviewer, and there is no second reviewer to escalate to. Record the conflict in your notes and be
conservative.

## 5. Enforcement actions (separate from the review)

None of these is done by `review_report`. Do the enforcement first, then set the status.

```sql
-- Disable an account. It vanishes from every READ path immediately.
update public.profiles set deleted_at = now() where id = '<subject-uuid>'::uuid;
```

**Known gap, disclosed rather than glossed:** disabling is a `profiles` update, so the account's JWT
stays valid and no write path re-checks the caller's own `deleted_at`. A disabled account can still
post, comment and cheer — invisibly to everyone else (`docs/MODERATION.md`). For a subject who is
actively abusing the service, disabling is therefore not containment. The complete measure today is
to delete the auth user in the dashboard's Authentication section, which is irreversible.

```sql
-- Take a post down AND schedule its photo for actual deletion. The enqueue is the part that
-- matters: soft-deleting the row only hides it, and the row holds the only copy of image_path.
with gone as (
  update public.posts set deleted_at = now()
   where id = '<post-id>'::uuid and deleted_at is null
  returning image_path
)
select public.enqueue_storage_object('post-images', image_path)
  from gone where image_path is not null;

-- Take a comment down.
update public.post_comments set deleted_at = now()
 where id = '<comment-id>'::uuid and deleted_at is null;

-- Remove an abusive avatar reference.
update public.profiles set avatar_path = null where id = '<subject-uuid>'::uuid;
```

The bytes are removed by the `storage-gc` Edge Function draining `storage_gc_queue`. If that job is
not scheduled, **nothing deletes the photo** — check `docs/RELEASE_CHECKLIST.md`.

## 6. Reports about accounts that no longer exist

A report survives deletion of the account it is about. `reported_user_id` becomes NULL and
`reported_user_key` keeps a stable pseudonym for the former subject
(`…20260101000300_social_tables.sql`). What survives: category, `created_at`, `reviewed_at`, the
reporter's `details`, and that key. What does not: any link to a person, and — because the content
links are also cleared — whether the report was originally about a post, a comment, or the account
as a whole. `category` is the only remaining hint.

Group the retained reports about one former account, if you still hold its uuid (e.g. from an earlier
report, a support thread, or a legal request):

```sql
select id, category, status, created_at, details
  from public.reports
 where reported_user_key = public.report_subject_key('<former-account-uuid>'::uuid)
 order by created_at desc;
```

...or group them without knowing any uuid, to see whether several retained reports concern one former
account:

```sql
select reported_user_key, count(*) as reports, min(created_at), max(created_at)
  from public.reports
 where reported_user_id is null
 group by reported_user_key
having count(*) > 1;
```

**What this cannot do.** The key is derived from the *account* id. A person who deletes their account
and registers again gets a new account id and therefore a completely unrelated key. There is **no
repeat-offender detection here** and nothing in this schema links a returning person to their old
records. Do not treat "a new account with a clean key" as evidence of anything, and do not describe
this capability to a user, a reviewer, or counsel as if it detected returning offenders.

The retained row is pseudonymised, not anonymous: it is still personal data under Art. 4(5), it still
carries a retention clock (§7), and anyone who independently holds the former account id can
recompute the key and confirm which rows concerned it. That recomputability is the point — it is what
lets you answer "produce the reports concerning this account" months later.

**A report the departing user *filed* is deleted with their account.** `reporter_id` still cascades.
So if someone reports harassment and then deletes their account, their report disappears — including
open reports about third parties. That asymmetry is a deliberate open question, not an oversight; see
§8.

## 7. Retention

| Class | Clock | Function |
|---|---|---|
| Resolved (`actioned`/`dismissed`) | 18 months after `reviewed_at` | `purge_resolved_reports(interval '18 months', …)` |
| Subject deleted, never resolved | 24 months after `created_at` | same function, second parameter |
| Subject live, never resolved | **No limit exists.** | none |

Both numbers are engineering defaults chosen for internal consistency and **require counsel
sign-off** — see [DATA_RETENTION_POLICY.md](legal/DATA_RETENTION_POLICY.md).

The third row is deliberate. A never-triaged report about a live account is a backlog, and the fix is
to triage it, not to have a job quietly destroy an open safety report. It does mean the queue is
unbounded if it is not worked, which is the operational argument for §9's target.

`purge_resolved_reports` is service-role only and **must be scheduled** or none of this happens
(`docs/RELEASE_CHECKLIST.md`). Run it by hand as the owner with:

```sql
select public.purge_resolved_reports();                  -- 18 months / 24 months defaults
select public.purge_resolved_reports(interval '18 months', interval '24 months');
```

## 8. Open decision: reports filed *by* a departing user

Today, `reporter_id` cascades: deleting your account deletes every report you filed. The retention
decision covered `reported_user_id` only. The same treatment (`on delete set null` plus the existing
pseudonymous subject key, which is about the subject and would be unaffected) would keep an open
report about a third party alive after its reporter leaves. It has not been done, because it is a
different balance — the reporter's own free-text account of an incident is *their* personal data, and
they have not been reported by anyone. Recorded here so it can be decided rather than drifted into.

## 9. App Store Review guideline 1.2

Guideline 1.2 requires an app with user-generated content to provide, among other things, **a
mechanism to report offensive content and timely responses to concerns**. Concretely:

- **A method for filtering objectionable material** — length caps and a server-side sanitiser on
  post and comment bodies, plus a constrained surface with no public posts and no DMs
  (`docs/MODERATION.md`). Partial and documented as such: profile text and usernames are sanitised
  client-side only.
- **A mechanism for users to flag offensive content** — `report_user`, `report_post` and
  `report_comment`, reachable from the profile, post and comment surfaces, all writing one queue.
- **The ability to block abusive users** — `block_user`, effective immediately and symmetric, with no
  moderator in the loop. This is the remedy that does not depend on the operator being awake.
- **Published contact information** — `support@cheekypint.app` (`docs/MODERATION.md`), still a
  placeholder that must be live before submission.
- **A timely response** — this is the half that had no implementation at all before `review_report`:
  the queue could be written but never transitioned, so nothing in the system could record that a
  report had been answered. It now can, and §1–§5 are the procedure.

**What "timely" means here, honestly.** One operator, checking the queue at least **every 48 hours**
and on the same day for `underage_concern` and `impersonation`. That is a target the operator has
committed to and can meet alone; it is not a contractual SLA, it is not staffed around the clock, and
it is not published to users as a promise. Users are told what is true: Block works instantly, and
reports are reviewed by a person. If the app ever grows past one person's capacity to hold that
target, the honest response is to add reviewers, not to lower the target quietly.

**Evidence for a reviewer, if asked.** The queue's schema and its transition function are in
`supabase/migrations/20260101000300_social_tables.sql` and
`supabase/migrations/20260813000100_review_report.sql`; the report-filing RPCs are in
`20260101000800_rpc_social.sql` and `20260811000700_rpc_feed_reports.sql`; the reporting UI is
`CheekyPint/Features/Moderation/ReportContentView.swift`; and this document is the process.
