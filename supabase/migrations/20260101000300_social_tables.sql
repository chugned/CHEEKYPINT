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
-- The moderation queue. A report SURVIVES the deletion of EITHER party, in minimised form, by two
-- operator decisions taken a day apart:
--
--   2026-08-13 (a): the reported account. `reported_user_id` was `not null ... on delete cascade`, so
--   a reported person erased every report about them — and the reporter's submitted evidence with it
--   — simply by deleting their account. That contradicted docs/legal/ACCOUNT_DELETION_POLICY.md and
--   pre-empted the 18-month clock in purge_resolved_reports.
--
--   2026-08-13 (b): the reporting account. `reporter_id` was `not null ... on delete cascade`, so the
--   reporter was the one party who could unilaterally destroy a live safety complaint ABOUT SOMEONE
--   ELSE, including one nobody had reviewed yet, just by leaving. It is now de-linked the same way —
--   but with one asymmetry, because the balance is genuinely different: the reporter's own free-text
--   account of events (`details`) is ERASED when they go, while the subject's departure leaves it
--   intact.
--
-- Why that asymmetry. `details` is up to 1,000 characters written BY the reporter, so it is the
-- reporter's own personal data as much as it is evidence about the subject. Retaining a subject's
-- report against their erasure request rests on Art. 17(3)(e) — defending claims about that subject
-- — and the reporter's text is the evidence that does the defending, so it stays. There is no
-- equivalent basis for keeping a departing reporter's prose about a third party once the reporter
-- themselves has asked to be erased: what the operator still needs from that row is the SIGNAL (a
-- complaint of this category was made about this subject on this date, pointing at this content), not
-- the complainant's narrative. So the signal is retained and the narrative is erased.
--
-- Honest cost, stated in docs/MODERATION_PROCESS.md too: for post and comment reports the real
-- evidence is the reported CONTENT, which post_id/comment_id still point at, so little is lost. For
-- an account-level report (no post_id, no comment_id) `details` may have been the ONLY evidence,
-- and clearing it can leave a row that records that a complaint existed without recording what it
-- alleged. That is a real loss, not a free trade.

-- The two party pseudonyms ----------------------------------------------------------------
--
-- One shared core so the digest construction and the `:v1:` version label can never drift between
-- the two roles; two thin wrappers so each role's DOMAIN LABEL is explicit at its call sites and
-- cannot be passed by accident.
--
-- SEPARATE NAMESPACES, deliberately. Using one namespace for both roles would make
-- report_reporter_key(X) equal report_subject_key(X), and an operator (or anyone holding a dump)
-- could then join any row's reporter key to any other row's subject key and learn "the person who
-- filed A is the person B is about" — across the whole retained corpus, with no account id in hand.
-- That correlation is not needed by either role's purpose (group reports about one former subject;
-- group reports filed by one former reporter), so Art. 5(1)(c) says do not create it. Note what
-- separate namespaces do NOT cost: an operator who legitimately holds the account id can still
-- compute both keys and compare them for that one person. What is removed is only the bulk,
-- id-free, cross-role linkage of a table whose whole point after de-linking is to hold no live
-- reference to a person.
--
-- What these keys do NOT do, and must never be described as doing: they cannot detect the same
-- human returning under a new account, in either role. A fresh registration gets a fresh account id
-- and therefore a completely unrelated key. Nothing device-, email-, or contact-derived feeds into
-- them. There is no repeat-offender detection here, by construction.
--
-- They are pseudonymisation in the Art. 4(5) sense, not anonymisation: the retained row is still
-- personal data and still carries a retention clock (see purge_resolved_reports). The derivation is
-- deterministic and unsalted, so anyone who independently still holds the former account id can
-- recompute the key and confirm which rows involved that account. That is deliberate — it is exactly
-- what lets the operator answer "produce the reports concerning this account" months later — and it
-- is why the row is treated as personal data rather than as anonymous statistics. A salted/keyed
-- (HMAC) variant would remove that confirmability at the cost of a secret that must survive every
-- dump/restore or all existing keys become meaningless; the `v1:` label exists so such a change can
-- be introduced as `v2:` without ambiguity, and report_party_key is the single place to change.
--
-- The uuid input carries ~122 bits of entropy, so the hash cannot be inverted by enumerating
-- candidate ids. All three are left executable by `authenticated` (via the blanket grant in
-- 20260101000900_grants.sql) on purpose: the derivation is public and unsalted, so revoking EXECUTE
-- would protect nothing a client could not compute itself, and the stamping trigger below calls
-- them under whatever role performs the insert.
create or replace function public.report_party_key(p_user_id uuid, p_domain text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
           when p_user_id is null then null
           else encode(
                  extensions.digest(
                    'cheekypint:' || p_domain || ':v1:' || p_user_id::text, 'sha256'),
                  'hex')
         end;
$$;

comment on function public.report_party_key(uuid, text) is
  'Shared core for the report party pseudonyms. p_domain separates the roles: a subject key and a '
  'reporter key for the SAME account are deliberately different values.';

create or replace function public.report_subject_key(p_user_id uuid)
returns text
language sql
immutable
set search_path = ''
as $$
  select public.report_party_key(p_user_id, 'report-subject');
$$;

comment on function public.report_subject_key(uuid) is
  'Stable pseudonym for a report SUBJECT: sha256 over a domain-separated string containing the '
  'account id. Groups reports about one former account after the id is de-linked. Cannot link a '
  'person to a NEW account — a new registration has a new id and therefore a different key. '
  'Deliberately a different value from report_reporter_key for the same account.';

create or replace function public.report_reporter_key(p_user_id uuid)
returns text
language sql
immutable
set search_path = ''
as $$
  select public.report_party_key(p_user_id, 'report-reporter');
$$;

comment on function public.report_reporter_key(uuid) is
  'Stable pseudonym for a REPORTER: groups the reports one former reporter filed, so a cluster of '
  'complaints about one subject can be told apart from many independent ones when answering a '
  'claim. Cannot link a person to a NEW account. Deliberately a different value from '
  'report_subject_key for the same account, so the two roles cannot be joined across the table.';

-- Both keys are stamped at INSERT time, not at deletion time, and both columns are NOT NULL.
-- Deliberate: a deletion-time trigger would be the single point of failure for the whole retention
-- guarantee, and it would fail SILENTLY (id nulled, key never written, record unattributable).
-- Stamping on insert means the guarantee is enforced by NOT NULL — a database constraint, not a
-- trigger — and if this trigger were ever dropped, inserts fail loudly instead of quietly losing a
-- key. (Contrast reports_erase_reporter_details below, where the trigger's job is an ERASURE, so the
-- silent-failure direction is reversed and a CHECK constraint has to catch it instead.)
create or replace function public.reports_stamp_party_keys()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- Both id columns are nullable so a report can OUTLIVE either party, not so a report can be filed
  -- by nobody or about nobody. A NEW report must still name two live accounts.
  if new.reporter_id is null then
    raise exception 'A report must name the account that filed it'
      using errcode = '23502';
  end if;
  if new.reported_user_id is null then
    raise exception 'A report must name the account it is about'
      using errcode = '23502';
  end if;
  new.reporter_key := public.report_reporter_key(new.reporter_id);
  new.reported_user_key := public.report_subject_key(new.reported_user_id);
  return new;
end;
$$;

-- Clearing `details` when the reporter is de-linked cannot be done by the foreign key: ON DELETE SET
-- NULL nulls the FK column and nothing else. So it needs a trigger — and a trigger that performs an
-- ERASURE has the opposite failure mode to one that stamps a value. If a stamping trigger stops
-- firing, a NOT NULL column rejects the write and you find out immediately. If THIS trigger stops
-- firing, the FK's set-null still runs, and the result is a de-linked row that quietly KEPT the
-- departed reporter's prose — an erasure that silently did not happen, which is the worst outcome
-- available and exactly the objection raised against a deletion-time trigger for the party keys.
--
-- So the invariant is enforced by the database, not by this trigger:
--
--     constraint report_details_erased_with_reporter check (reporter_id is not null or details is null)
--
-- The trigger merely SATISFIES that constraint. If it is dropped, disabled, or recreated wrongly, the
-- FK's set-null update violates the CHECK and the whole account deletion ABORTS, in the same
-- transaction, naming the constraint. Loud, immediate, and — because it is one transaction — it can
-- never leave a half-erased report or skip a row: either every affected report is cleared and the
-- account is deleted, or nothing changes at all.
--
-- BEFORE UPDATE on public.reports rather than BEFORE DELETE on public.profiles, which would also
-- work and would also abort the delete. Reasons for keeping it on this table: the invariant belongs
-- to public.reports, and a trigger on `profiles` maintaining `reports` is invisible to anyone reading
-- either table's definition; it needs no cross-table `where reporter_id = old.id` sweep, so there is
-- no per-row skip to reason about; and it covers EVERY route that de-links a reporter, including a
-- manual `update reports set reporter_id = null`, not only the profile-deletion route.
--
-- The condition is written twice on purpose — once as the trigger's WHEN clause, where it is visible
-- in \d output and avoids calling the function on unrelated updates, and once in the body. The body
-- guard is not redundant defensive noise: if someone recreated this trigger without the WHEN clause,
-- an unconditional body would null `details` on EVERY update to the table, including every
-- review_report call. That is silent, total data loss, so it gets a second guard.
create or replace function public.reports_erase_reporter_details()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.reporter_id is not null and new.reporter_id is null then
    new.details := null;
  end if;
  return new;
end;
$$;

create table public.reports (
  id uuid primary key default gen_random_uuid(),
  -- set null, not cascade: the report outlives BOTH parties (see header). The reporter's own
  -- free-text `details` is erased at the same moment by reports_erase_reporter_details.
  reporter_id uuid references public.profiles (id) on delete set null,
  reporter_key text not null
    constraint report_reporter_key_format check (reporter_key ~ '^[0-9a-f]{64}$'),
  reported_user_id uuid references public.profiles (id) on delete set null,
  reported_user_key text not null
    constraint report_subject_key_format check (reported_user_key ~ '^[0-9a-f]{64}$'),
  category public.report_category not null,
  details text constraint report_details_length check (details is null or char_length(details) <= 1000),
  status public.report_status not null default 'open',
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  -- NULL-safe on BOTH sides, which it has to be now that either party can be de-linked:
  --   * a bare `reporter_id <> reported_user_id` evaluates to NULL — which a CHECK treats as
  --     satisfied — as soon as either side is NULL, so it stops constraining the new rows entirely;
  --   * `reporter_id is distinct from reported_user_id` (the previous form, correct while
  --     reporter_id was NOT NULL) is the opposite trap: for a row that has lost BOTH parties it
  --     evaluates `null is distinct from null` = FALSE and would BLOCK the second de-link, i.e.
  --     account deletion would start failing once a report's other party had already gone.
  -- The explicit three-way form is total AND admits every partially- or fully-de-linked row.
  constraint report_not_self check (
    reporter_id is null or reported_user_id is null or reporter_id <> reported_user_id
  ),
  -- The reporter's prose does not outlive the reporter. This is the guarantee; the trigger above is
  -- only its mechanism. See that comment for why the constraint, not the trigger, is the guard.
  constraint report_details_erased_with_reporter check (
    reporter_id is not null or details is null
  ),
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
  'Moderation report queue for operator review. Survives deletion of EITHER party: the id column is '
  'de-linked and the matching pseudonymous key is retained. Deleting the reporter additionally '
  'erases their free-text details. Transitioned only by public.review_report (service role).';
comment on column public.reports.reporter_id is
  'The reporting account while it exists; NULL once that account is deleted (on delete set null), at '
  'which point details is erased too.';
comment on column public.reports.reporter_key is
  'Stable pseudonym for the reporting account, stamped at insert. Lets the reports one former '
  'reporter filed be grouped, so a cluster of complaints about one subject can be told apart from '
  'many independent ones. A DIFFERENT value from reported_user_key for the same account, on purpose.';
comment on column public.reports.reported_user_id is
  'The reported account while it exists; NULL once that account is deleted (on delete set null).';
comment on column public.reports.reported_user_key is
  'Stable pseudonym for the reported account, stamped at insert. Survives deletion of the account '
  'so retained reports about one former account can still be grouped. Does NOT identify a person '
  'across accounts: a new registration produces a different key.';
comment on column public.reports.details is
  'Up to 1000 characters written by the reporter. Erased when the reporter''s account is deleted '
  '(report_details_erased_with_reporter); survives deletion of the reported account, because it is '
  'the evidence the Art. 17(3)(e) retention exists to preserve.';

create trigger reports_stamp_party_keys
  before insert on public.reports
  for each row execute function public.reports_stamp_party_keys();

create trigger reports_erase_reporter_details
  before update on public.reports
  for each row
  when (old.reporter_id is not null and new.reporter_id is null)
  execute function public.reports_erase_reporter_details();

create index reports_status_idx on public.reports (status, created_at);
-- BOTH keys are indexed, deliberately. reports_reported_idx still serves live-account triage
-- ("other reports about this account") AND the `on delete set null` action itself, which looks
-- rows up by reported_user_id on every account deletion — dropping it would turn each deletion
-- into a sequential scan of the queue. reports_reported_key_idx is the only way to group RETAINED
-- reports, whose reported_user_id is NULL and therefore useless as a grouping key.
create index reports_reported_idx on public.reports (reported_user_id);
create index reports_reported_key_idx on public.reports (reported_user_key);
-- Same argument on the reporter side, plus one more: reports_select_own
-- (20260101000700_rls_policies.sql) filters on reporter_id, so this serves the only client read path
-- the table has. The lookup-per-account-deletion cost applied to the old `on delete cascade` too —
-- this column has simply never been indexed, and the `set null` action needs it just as much.
create index reports_reporter_idx on public.reports (reporter_id);
create index reports_reporter_key_idx on public.reports (reporter_key);
