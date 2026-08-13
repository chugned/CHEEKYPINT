# Data Retention Policy — CheekyPint

> **Template requiring review by a qualified legal professional before production launch.**
> Complete `[[placeholders]]`.

## Principle

We keep personal data only as long as needed to run CheekyPint, meet legal obligations, and keep
the service safe.

## Retention schedule

| Data | Retention |
|------|-----------|
| Account + profile | While the account is active |
| Pint entries / pub visits | While active; soft-deleted immediately on undo/deletion, purged within [[30]] days |
| Post bodies / photos | While active; soft-deleted immediately on author deletion, purged within 30 days (`purge_soft_deleted_posts`); the photo is queued for storage removal at the same time |
| Comments / reactions on posts | Comments: while active; soft-deleted immediately on author deletion, purged within 30 days (`purge_soft_deleted_comments`). Reactions (cheers) have no independent soft-delete — see note below |
| Friends / blocks | While active or until removed/unblocked |
| Reports (moderation), resolved | [[12–24 months]] after resolution, for safety and audit (`purge_resolved_reports`, defaults to 18 months from the review decision) |
| Reports (moderation), where the reported account has been deleted | Kept without the reported person's identity; deleted [[24 months]] after the report was filed if it was never resolved, or on the resolved schedule above if it was — see "Reports about deleted accounts" below |
| Reports (moderation), where the **reporting** account has been deleted | Kept without the reporter's identity **and without the text they wrote**, which is erased; otherwise on the schedules above |
| Reports (moderation), unresolved, reported account still active | **No defined period.** Kept until reviewed. See the note below |
| Rate-limit events | Rolling [[2 days]] (pruned automatically) |
| Analytics events (if enabled) | Aggregated/identifier-free; [[14 months]] |
| Backups | Rolling [[7–30]] days, then overwritten |
| Auth logs | Per Supabase configuration ([[window]]) |

**Note on comments and reactions:** deleting a post also removes the comments and reactions
(cheers) other people left on it. This is deliberate — a comment or reaction has no meaning or
place to appear once its post is gone. It happens at purge time, not at the moment of deletion:
soft-deleting a post only hides it; the comments and reactions on it are removed later, together
with the post itself, when the post's own 30-day purge runs. A comment made on a post before that
post was soft-deleted is removed this way even though the comment itself was never soft-deleted
and was not independently due for deletion.

## Reports involving deleted accounts

A moderation report is not deleted when either person involved in it deletes their account. In both
cases the link to that person is removed and replaced with a one-way pseudonymous key, so that related
reports can still be grouped. We keep the record to be able to defend or answer legal claims and to
audit our own moderation decisions (Art. 17(3)(e)).

**If the person a report is about deletes their account**, the report keeps its category, its dates and
what the reporter wrote. The reporter's description is the evidence the retention exists to preserve,
so it stays.

**If the person who filed a report deletes their account**, the report keeps its category, its dates
and the link to the reported content — but **the text they wrote is erased.** Their description of what
happened is their own personal data, and once they have asked to be erased we have no basis to keep
their account of events about someone else. What we keep is the fact that a complaint of that kind was
made on that date, not their words. We do this rather than deleting the whole report because otherwise
the person who reports harassment could, by leaving, destroy the record of a complaint about somebody
else — including one we had not yet reviewed.

Three honest limits:

- Neither key lets us recognise the same person if they sign up again. Both are derived from the
  deleted account, and a new registration is a new account with different keys. **We do not track
  people across accounts.**
- The two keys are deliberately different from each other, so we cannot use them to work out that the
  person who filed one report is the person another report is about.
- Both are **pseudonymisation, not anonymisation**. A retained report is still personal data, still
  covered by this policy, and still deleted on the schedule in the table above.

> **[[24 months from filing]] and [[18 months from resolution]] require sign-off by a qualified legal
> professional.** These are engineering defaults chosen so the two cases expire at roughly the same
> point after a report is filed, and so both stay inside the 12–24 month window published above. They
> are **not** legal advice and were not derived from any limitation period. Counsel must confirm (or
> replace) both numbers, and confirm that retention against an erasure request is justified here at
> all, before launch.

**Note on unresolved reports about active accounts.** These have no expiry date, on purpose: the
correct response to a report nobody has reviewed is to review it, not to have a scheduled job destroy
an open safety complaint. That holds whether or not the person who filed it has since left. The
consequence is that the queue grows without limit if it is not worked;
[MODERATION_PROCESS.md](../MODERATION_PROCESS.md) is the process that keeps it worked, and this is the
reason it matters. A report where **both** people involved have deleted their accounts does have an
expiry date — [[24 months]] from when it was filed — so it cannot be kept indefinitely.

## On account deletion

1. Profile is anonymised and marked deleted (disappears from all surfaces immediately).
2. Friend tokens revoked; friendships and blocks removed; sessions left.
3. Pint entries soft-deleted, then purged on the schedule above.
4. Avatar files and post photo files removed from storage; the auth user is deleted (cascade) by
   the `delete-account` Edge Function, which the app invokes as part of deletion. This removes the
   files at those storage paths; a photo URL already copied, screenshotted, or shared elsewhere
   before deletion cannot be recalled.

See the [Account Deletion Policy](ACCOUNT_DELETION_POLICY.md).

## Legal holds

We may retain specific data longer where required by law or to resolve a dispute/safety matter,
limited to what is necessary.

**Contact:** [[privacy@cheekypint.app]].
