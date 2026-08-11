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
| Reports (moderation) | [[12–24 months]] after resolution, for safety and audit (`purge_resolved_reports`, defaults to 18 months) |
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
