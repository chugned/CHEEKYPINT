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
       reporter_id, reporter_key, reported_user_id, reported_user_key,
       post_id, comment_id, details
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

## 6. Reports whose parties no longer exist

A report survives deletion of **either** party. The id column is de-linked to NULL and the matching
pseudonymous key is retained (`…20260101000300_social_tables.sql`).

| The account that left | What is kept | What is lost |
|---|---|---|
| The **reported** account | Category, `created_at`, `reviewed_at`, the reporter's `details`, `reported_user_key`, and the reporter's own identity | The link to the reported person; and, because the content links are cleared with them, whether the report was about a post, a comment, or the account as a whole — `category` is the only remaining hint |
| The **reporting** account | Category, `created_at`, `reviewed_at`, `reporter_key`, the reported person's identity (if still live), and `post_id`/`comment_id` | The link to the reporter, **and their `details` text — erased, not de-linked** |

**Why `details` goes when the reporter goes.** It is up to 1,000 characters written *by* the reporter,
so it is their own personal data as much as it is evidence about someone else. Keeping a *subject's*
report against their erasure request rests on Art. 17(3)(e) — defending claims about that subject —
and the reporter's text is the evidence that does the defending, so it stays. There is no equivalent
basis for keeping a departing reporter's narrative about a third party after they have asked to be
erased. What is kept is the **signal** (a complaint of this category was made about this subject on
this date, pointing at this content); what goes is the **narrative**.

**What that costs, plainly.** For a **post or comment report** the real evidence is the reported
content itself, which `post_id`/`comment_id` still point at, so little is lost — the prose was
commentary on evidence you can still open. For an **account-level report** (no `post_id`, no
`comment_id`) the free text may have been the *only* evidence, and clearing it can leave a row that
records that a complaint of some category existed without recording what it alleged. That is a real
loss, not a free trade. If a specific account report matters and its reporter still exists, resolve it
while you can still read it.

The two keys are in **separate namespaces**, deliberately: `report_reporter_key(X)` and
`report_subject_key(X)` are different values for the same account X. That means you cannot join one
row's reporter key to another row's subject key to discover that the person who filed A is the person
B is about. If you legitimately need that comparison for one person and you hold their account id, you
can still compute both keys yourself and compare — what is prevented is doing it in bulk, across the
whole table, with no id in hand.

Group the retained reports about one former account, if you still hold its uuid (e.g. from an earlier
report, a support thread, or a legal request):

```sql
select id, category, status, created_at, details
  from public.reports
 where reported_user_key = public.report_subject_key('<former-account-uuid>'::uuid)
 order by created_at desc;
```

...the reports a former account **filed** (note `details` will be NULL on all of them):

```sql
select id, category, status, created_at, reported_user_id, post_id, comment_id
  from public.reports
 where reporter_key = public.report_reporter_key('<former-account-uuid>'::uuid)
 order by created_at desc;
```

...or group them without knowing any uuid — useful when answering a claim, to see whether a cluster of
complaints about one former subject came from one complainant or from many independent ones:

```sql
-- retained reports grouped by former subject
select reported_user_key, count(*) as reports,
       count(distinct reporter_key) as distinct_reporters,
       min(created_at), max(created_at)
  from public.reports
 where reported_user_id is null
 group by reported_user_key
having count(*) > 1;

-- reports left behind by departed reporters
select reporter_key, count(*) as reports, min(created_at), max(created_at)
  from public.reports
 where reporter_id is null
 group by reporter_key;
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

Both retained rows are **pseudonymised, not anonymous**: still personal data under Art. 4(5), still on
a retention clock (§7), and anyone who independently holds the former account id can recompute either
key and confirm which rows involved it. That recomputability is the point — it is what lets you answer
"produce the reports concerning this account" months later.

**Neither key identifies a person across accounts.** Both are derived from the *account* id, so a
person who deletes their account and registers again gets a new id and therefore unrelated keys, in
both roles. There is **no repeat-offender detection here.** Do not treat "a new account with clean
keys" as evidence of anything, and do not describe this capability to a user, a reviewer, or counsel as
if it detected returning offenders.

## 7. Retention

| Class | Clock | Function |
|---|---|---|
| Resolved (`actioned`/`dismissed`) | 18 months after `reviewed_at` | `purge_resolved_reports(interval '18 months', …)` |
| Subject deleted, never resolved — including rows where the **reporter is also gone** | 24 months after `created_at` | same function, second parameter |
| Subject live, never resolved — whether or not the reporter has left | **No limit exists.** | none |

Both numbers are engineering defaults chosen for internal consistency and **require counsel
sign-off** — see [DATA_RETENTION_POLICY.md](legal/DATA_RETENTION_POLICY.md).

The second row deliberately covers the **fully de-linked** report — no reporter and no subject. That
row has no living party left to trigger any other cleanup, so if the purge missed it, it would be
retained forever; the branch keys on `reported_user_id is null`, which catches it.

The third row is deliberate. A never-triaged report about a live account is a backlog, and the fix is
to triage it, not to have a job quietly destroy an open safety report. A reporter having departed does
not make a complaint about a live account less worth reading — it makes it harder to follow up, which
is an argument for triaging sooner, not for deleting. Such a row keeps its category, dates and content
links indefinitely, though its `details` has already gone with its reporter. That the queue is
unbounded if it is not worked is the operational argument for §9's target.

`purge_resolved_reports` is service-role only and **must be scheduled** or none of this happens
(`docs/RELEASE_CHECKLIST.md`). Run it by hand as the owner with:

```sql
select public.purge_resolved_reports();                  -- 18 months / 24 months defaults
select public.purge_resolved_reports(interval '18 months', interval '24 months');
```

## 8. Decided: reports filed *by* a departing user

**Resolved 2026-08-13.** `reporter_id` previously cascaded, so deleting your account deleted every
report you filed — which made the reporter the one party who could unilaterally destroy a live safety
complaint *about someone else*, including one nobody had reviewed yet, simply by leaving.

It is now `on delete set null` with `reporter_key` retained and `details` erased, per §6. The
operational consequences for you:

- A queue read can contain reports with no reporter to follow up with. Those rows have no `details`,
  so for an account-level report you may be looking at a category and a date and nothing else. Judging
  such a report on the reported content (if any) is all that remains; dismissing it for lack of
  evidence is a legitimate outcome, and `dismissed` is the honest status for it.
- Those rows are invisible to every client, including the app — `reports_select_own` is
  `reporter_id = auth.uid()`, which matches nothing once the column is NULL. They exist only for you,
  in the dashboard.
- Nothing else about them changes: they still transition through `review_report`, still carry the
  subject's identity while that account lives, and still expire on the §7 clocks.

The cost of the erasure is stated plainly in §6 rather than glossed: it is cheap for content reports
and genuinely expensive for account-level ones.

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

**A note on de-linked rows and 1.2.** A report whose reporter has left keeps its category, dates and
content links but loses the reporter's text (§6). That does not weaken the reporting mechanism — the
mechanism is the ability to file and have a person respond, both of which are unaffected — but it does
mean some rows in the queue cannot be adjudicated on their text. Resolve reports while their reporters
still exist; that is another reason the §9 target matters.

**Evidence for a reviewer, if asked.** The queue's schema and its transition function are in
`supabase/migrations/20260101000300_social_tables.sql` and
`supabase/migrations/20260813000100_review_report.sql`; the report-filing RPCs are in
`20260101000800_rpc_social.sql` and `20260811000700_rpc_feed_reports.sql`; the reporting UI is
`CheekyPint/Features/Moderation/ReportContentView.swift`; and this document is the process.
