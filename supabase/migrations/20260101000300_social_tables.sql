-- CheekyPint schema — 03. Social tables: friendships, blocks, reports

-- friendships ---------------------------------------------------------------------------
-- Directed edge (requester → addressee). A canonical (least, greatest) pair is stored in
-- generated columns so a single partial unique index prevents duplicate *active*
-- relationships in either direction.
create table public.friendships (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.profiles (id) on delete cascade,
  addressee_id uuid not null references public.profiles (id) on delete cascade,
  status public.friendship_status not null default 'pending',
  requested_at timestamptz not null default now(),
  responded_at timestamptz,
  updated_at timestamptz not null default now(),
  user_low uuid generated always as (least(requester_id, addressee_id)) stored,
  user_high uuid generated always as (greatest(requester_id, addressee_id)) stored,
  constraint friendship_not_self check (requester_id <> addressee_id)
);

comment on table public.friendships is 'Directed friendship edges; only accepted rows grant mutual visibility.';

-- At most one live (pending or accepted) relationship per unordered pair.
create unique index friendships_unique_active_pair
  on public.friendships (user_low, user_high)
  where status in ('pending', 'accepted');

create index friendships_requester_idx on public.friendships (requester_id);
create index friendships_addressee_idx on public.friendships (addressee_id);
create index friendships_accepted_low_idx on public.friendships (user_low) where status = 'accepted';
create index friendships_accepted_high_idx on public.friendships (user_high) where status = 'accepted';

create trigger friendships_set_updated_at
  before update on public.friendships
  for each row execute function public.set_updated_at();

-- blocks --------------------------------------------------------------------------------
-- A block overrides every friendship/leaderboard/session rule. Directed row, symmetric
-- effect on visibility.
create table public.blocks (
  blocker_id uuid not null references public.profiles (id) on delete cascade,
  blocked_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  constraint block_not_self check (blocker_id <> blocked_id)
);

comment on table public.blocks is 'Blocks override all other visibility. Effect is symmetric even though the row is directed.';

create index blocks_blocked_idx on public.blocks (blocked_id);

-- reports -------------------------------------------------------------------------------
-- The moderation queue. Operator decision (2026-08-13): a report SURVIVES the deletion of the
-- account it is about, in minimised form. Before that decision `reported_user_id` was
-- `not null ... on delete cascade`, so a reported person erased every report about them — and the
-- reporter's own submitted evidence with it — simply by deleting their account, which also
-- contradicted docs/legal/ACCOUNT_DELETION_POLICY.md and pre-empted the 18-month clock in
-- purge_resolved_reports. Retention is justified under Art. 17(3)(e) (establishment/exercise/
-- defence of legal claims) and for audit of the moderation process itself; the retained row keeps
-- the category, the timestamps, the reporter's details text, and the pseudonymous subject key
-- below, and holds NO live reference to a person.
--
-- `reporter_id` deliberately still cascades. That is a separate question the operator has not
-- decided: today, a reporter deleting their account destroys the reports they filed, including
-- reports about other people that are still open. See docs/MODERATION_PROCESS.md.

-- report_subject_key: the stable pseudonym for a report's subject.
--
-- Derived from the subject's ACCOUNT id, so every report about one account gets the same key and
-- the operator can still group them ("everything filed about the account this claim concerns")
-- after reported_user_id has been de-linked.
--
-- What this key does NOT do, and must never be described as doing: it cannot detect the same
-- human returning under a new account. A fresh registration gets a fresh account id and therefore
-- a completely unrelated key. Nothing device-, email-, or contact-derived feeds into it. There is
-- no repeat-offender detection here, by construction.
--
-- It is pseudonymisation in the Art. 4(5) sense, not anonymisation: the retained row is still
-- personal data and still carries a retention clock (see purge_resolved_reports). The derivation
-- is deterministic and unsalted, so anyone who independently still holds the former account id can
-- recompute the key and confirm which rows were about that account. That is deliberate — it is
-- exactly what lets the operator answer "produce the reports concerning this account" months later
-- — and it is why the row is treated as personal data rather than as anonymous statistics. A
-- salted/keyed (HMAC) variant would remove that confirmability at the cost of a secret that must
-- survive every dump/restore or all existing keys become meaningless; the `v1:` label in the
-- derivation string exists so such a change can be introduced as `v2:` without ambiguity.
--
-- The uuid input carries ~122 bits of entropy, so the hash cannot be inverted by enumerating
-- candidate ids. Left executable by `authenticated` (via the blanket grant in
-- 20260101000900_grants.sql) on purpose: the derivation is public and unsalted, so revoking EXECUTE
-- would protect nothing a client could not compute itself, and the stamping trigger below calls it
-- under whatever role performs the insert.
create or replace function public.report_subject_key(p_user_id uuid)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
           when p_user_id is null then null
           else encode(
                  extensions.digest('cheekypint:report-subject:v1:' || p_user_id::text, 'sha256'),
                  'hex')
         end;
$$;

comment on function public.report_subject_key(uuid) is
  'Stable pseudonym for a report subject: sha256 over a domain-separated string containing the '
  'account id. Groups reports about one former account after the id is de-linked. Cannot link a '
  'person to a NEW account — a new registration has a new id and therefore a different key.';

-- Stamped at INSERT time, not at deletion time, and the column is NOT NULL. Deliberate: a
-- deletion-time trigger would be the single point of failure for the whole retention guarantee,
-- and it would fail SILENTLY (id nulled, key never written, record unattributable). Stamping on
-- insert means the guarantee is enforced by NOT NULL — a database constraint, not a trigger — and
-- if this trigger were ever dropped, inserts fail loudly instead of quietly losing the key.
--
-- INSERT-only on purpose: a BEFORE UPDATE variant would have to special-case the FK's own
-- `set null` update, and getting that wrong would block account deletion outright.
create or replace function public.reports_stamp_subject_key()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- reported_user_id is nullable so a report can OUTLIVE its subject, not so a report can be
  -- filed about nobody. A new report must still name a live account.
  if new.reported_user_id is null then
    raise exception 'A report must name the account it is about'
      using errcode = '23502';
  end if;
  new.reported_user_key := public.report_subject_key(new.reported_user_id);
  return new;
end;
$$;

create table public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references public.profiles (id) on delete cascade,
  -- set null, not cascade: the report outlives the reported account (see header).
  reported_user_id uuid references public.profiles (id) on delete set null,
  reported_user_key text not null
    constraint report_subject_key_format check (reported_user_key ~ '^[0-9a-f]{64}$'),
  category public.report_category not null,
  details text constraint report_details_length check (details is null or char_length(details) <= 1000),
  status public.report_status not null default 'open',
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  -- NULL-safe on purpose. `reporter_id <> reported_user_id` evaluates to NULL — which a CHECK
  -- treats as satisfied — for every row whose subject has been de-linked, so the plain `<>` form
  -- stops constraining exactly the rows this change introduces. `is distinct from` is total.
  -- NOTE for whoever gives reporter_id the same treatment: with BOTH columns nullable, a row that
  -- has lost both parties evaluates `null is distinct from null` = false and this constraint would
  -- then BLOCK the second de-link. It must become
  -- `(reporter_id is null or reported_user_id is null or reporter_id <> reported_user_id)` at the
  -- same time.
  constraint report_not_self check (reporter_id is distinct from reported_user_id),
  -- reviewed_at is the retention clock's zero point — purge_resolved_reports keys off it
  -- (20260812000400_retention_purges.sql) — so it must be present exactly when the report is
  -- resolved and absent otherwise. Without this, a manual `update reports set status = 'actioned'`
  -- run from the dashboard leaves reviewed_at NULL and makes the row immortal, which is precisely
  -- the state the entire queue was in before public.review_report existed.
  constraint report_reviewed_at_matches_status check (
    (status in ('actioned', 'dismissed')) = (reviewed_at is not null)
  )
);

comment on table public.reports is
  'Moderation report queue for operator review. Survives deletion of the reported account: '
  'reported_user_id is de-linked and reported_user_key retains a stable pseudonym for the former '
  'subject. Transitioned only by public.review_report (service role).';
comment on column public.reports.reported_user_id is
  'The reported account while it exists; NULL once that account is deleted (on delete set null).';
comment on column public.reports.reported_user_key is
  'Stable pseudonym for the reported account, stamped at insert. Survives deletion of the account '
  'so retained reports about one former account can still be grouped. Does NOT identify a person '
  'across accounts: a new registration produces a different key.';

create trigger reports_stamp_subject_key
  before insert on public.reports
  for each row execute function public.reports_stamp_subject_key();

create index reports_status_idx on public.reports (status, created_at);
-- BOTH keys are indexed, deliberately. reports_reported_idx still serves live-account triage
-- ("other reports about this account") AND the `on delete set null` action itself, which looks
-- rows up by reported_user_id on every account deletion — dropping it would turn each deletion
-- into a sequential scan of the queue. reports_reported_key_idx is the only way to group RETAINED
-- reports, whose reported_user_id is NULL and therefore useless as a grouping key.
create index reports_reported_idx on public.reports (reported_user_id);
create index reports_reported_key_idx on public.reports (reported_user_key);
