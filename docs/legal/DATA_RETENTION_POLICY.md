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
| Friends / blocks | While active or until removed/unblocked |
| Reports (moderation) | [[12–24 months]] after resolution, for safety and audit |
| Rate-limit events | Rolling [[2 days]] (pruned automatically) |
| Analytics events (if enabled) | Aggregated/identifier-free; [[14 months]] |
| Backups | Rolling [[7–30]] days, then overwritten |
| Auth logs | Per Supabase configuration ([[window]]) |

## On account deletion

1. Profile is anonymised and marked deleted (disappears from all surfaces immediately).
2. Friend tokens revoked; friendships and blocks removed; sessions left.
3. Pint entries soft-deleted, then purged on the schedule above.
4. Avatar files removed from storage; the auth user is deleted (cascade) by the
   `delete-account` Edge Function.

See the [Account Deletion Policy](ACCOUNT_DELETION_POLICY.md).

## Legal holds

We may retain specific data longer where required by law or to resolve a dispute/safety matter,
limited to what is necessary.

**Contact:** [[privacy@cheekypint.app]].
