# Account Deletion Policy — CheekyPint

> **Template requiring review by a qualified legal professional before production launch.**

You can delete your CheekyPint account entirely **from inside the app** — no emailing support
required (Apple App Store Guideline 5.1.1(v)).

## How to delete

**Settings → Delete account.** We explain what will be removed, ask you to type `DELETE` to
confirm, and may ask you to re-authenticate.

## What happens

1. Your profile is anonymised and marked deleted — it disappears from friends' lists, standings,
   sessions, and previews immediately.
2. Your friend codes are revoked; friendships and blocks are removed; active sessions are left.
3. Your pint diary and pub visits are soft-deleted and then purged per the
   [Data Retention Policy](DATA_RETENTION_POLICY.md).
4. Your profile photo is removed from storage and your authentication account is deleted (this
   cascade is completed by the `delete-account` Edge Function using the service role).
5. You are signed out and shown a confirmation.

## What may remain

- Moderation reports you filed or that concern safety may be retained (anonymised where possible)
  for the period in the Data Retention Policy.
- Residual copies in encrypted backups roll off on the backup schedule.
- Anonymous, non-identifying aggregate analytics are unaffected.

## Timing

App-visible data is removed immediately; storage/auth removal completes shortly after; backups
within the stated window.

**Questions:** [[privacy@cheekypint.app]].
