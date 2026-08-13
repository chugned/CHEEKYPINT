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

## Reports about deleted accounts

If someone deletes their CheekyPint account, reports **about** them are not deleted with it. The
report keeps its category, its dates, and what the reporter wrote; the link to the person is removed
and replaced with a one-way pseudonymous key so that reports about the same former account can still
be grouped. We keep this to be able to defend or answer legal claims and to audit our own moderation
decisions (Art. 17(3)(e)).

Two honest limits on what that key is:

- It **does not** let us recognise the same person if they sign up again. The key is derived from the
  deleted account, and a new registration is a new account with a different key. We do not track
  people across accounts.
- It is **pseudonymisation, not anonymisation**. The retained report is still personal data, still
  covered by this policy, and still deleted on the schedule in the table above.

Reports that the departing user **filed** are deleted along with their account.

> **[[24 months from filing]] and [[18 months from resolution]] require sign-off by a qualified legal
> professional.** These are engineering defaults chosen so the two cases expire at roughly the same
> point after a report is filed, and so both stay inside the 12–24 month window published above. They
> are **not** legal advice and were not derived from any limitation period. Counsel must confirm (or
> replace) both numbers, and confirm that retention against an erasure request is justified here at
> all, before launch.

**Note on unresolved reports about active accounts.** These have no expiry date, on purpose: the
correct response to a report nobody has reviewed is to review it, not to have a scheduled job destroy
an open safety complaint. The consequence is that the queue grows without limit if it is not worked;
[MODERATION_PROCESS.md](../MODERATION_PROCESS.md) is the process that keeps it worked, and this is the
reason it matters.

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
