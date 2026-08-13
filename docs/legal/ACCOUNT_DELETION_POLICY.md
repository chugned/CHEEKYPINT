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
4. Your profile photo and any photos on your posts are removed from storage and your
   authentication account is deleted — completed by the `delete-account` Edge Function, which the
   app calls using the service role. This removes the files at those storage paths; it cannot
   recall a photo URL you or someone else already copied, screenshotted, or shared elsewhere
   before deletion.
5. You are signed out and shown a confirmation.

## What may remain

- **Reports other people made about you are kept, without your identity.** We remove the link to your
  account and keep the report itself — its category, its dates, and what the reporter wrote — so that
  we can answer or defend legal claims and audit our own moderation decisions. A one-way
  pseudonymous key replaces your identity so that reports about the same former account can still be
  grouped together; it **cannot** recognise you if you sign up again, because a new account is a new
  identity to us. These reports are deleted on the schedule in the
  [Data Retention Policy](DATA_RETENTION_POLICY.md).
- **Reports you filed are kept, without your identity and without your words.** We remove the link to
  your account and **erase the description you wrote**, keeping only the fact that a report of that
  category was made on that date, who or what it was about, and the reported post or comment if there
  was one. We keep that much because otherwise someone who reports harassment could erase the record of
  their complaint about another person simply by closing their account — including a complaint we had not
  yet reviewed. We erase your description because those are your words about someone else, and once you
  have asked to be erased we have no good reason to keep them. These reports are deleted on the schedule
  in the [Data Retention Policy](DATA_RETENTION_POLICY.md).
- Residual copies in encrypted backups roll off on the backup schedule.
- Anonymous, non-identifying aggregate analytics are unaffected.

## Timing

App-visible data is removed immediately; storage/auth removal completes shortly after; backups
within the stated window.

**Questions:** [[privacy@cheekypint.app]].
