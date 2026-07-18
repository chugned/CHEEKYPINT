# Moderation

Because users can upload profile photos and text, CheekyPint includes basic UGC protection while
keeping the social surface deliberately small to make moderation tractable.

## Constrained surface (by design)

No public posts, comments, direct messages, anonymous chat, or image feeds in the MVP. The only
user-visible UGC is: display name, username, bio, avatar, and pub suggestions.

## User tools

- **Block** — overrides all visibility both directions; tears down friendship + pending requests.
- **Report** — `report_user(target, category, details)`; categories include inappropriate image/
  text, harassment, impersonation, underage concern, other. Rate-limited.
- **Remove friend** — ends the relationship without blocking.

## Preventive controls

- Length limits + sanitisation on display name (40), bio (160), city (60), note (280); control/
  format/zero-width/bidi characters stripped (`ProfileTextSanitizer`, tested).
- Username validation + reserved-word list to reduce impersonation (`admin`, `support`, …).
- Resized avatars only; storage writes restricted to the user's own folder.

## Admin / back office

- `reports` table is a queue (`open → reviewing → actioned → dismissed`) with indexes on
  `(status, created_at)` and `reported_user_id`.
- An administrator can disable an abusive profile by setting `profiles.deleted_at` (removes it
  from every surface) via the service role / an internal tool. A dedicated admin RPC and audit
  log are a fast-follow.
- Support contact: `support@cheekypint.app` (placeholder).

## Escalation

Underage-concern and impersonation reports should be triaged first. Serious safety reports may
warrant immediate profile disable pending review.
