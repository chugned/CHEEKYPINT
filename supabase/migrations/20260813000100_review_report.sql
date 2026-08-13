-- CheekyPint: review_report — the one way a moderation report changes state.
--
-- Until this migration the queue was WRITE-ONLY. `public.report_status` has had four values since
-- 20260101000100_extensions_and_enums.sql:36, but nothing in the entire schema ever set
-- `reports.status` or `reports.reviewed_at` — every `set status` in the migrations belongs to
-- friendships or pub_sessions. Three consequences, all of which this closes:
--
--   1. `public.purge_resolved_reports` (20260812000400_retention_purges.sql) matched
--      `status in ('actioned','dismissed') and reviewed_at < …`, i.e. a predicate no row could ever
--      satisfy. It was dead code, and the 18-month commitment in
--      docs/legal/DATA_RETENTION_POLICY.md was unenforceable in principle, not merely unscheduled.
--   2. There was no record of whether a report had been looked at, so a re-read of the queue could
--      not distinguish "new" from "already handled and dismissed".
--   3. App Store Review guideline 1.2 asks for a mechanism to report content AND a timely response
--      to it. The reporting mechanism existed; nothing recorded a response.
--
-- Deliberately NOT included, so the omissions are visible rather than assumed:
--   * No reviewer identity. There is no moderator role and no second account — the operator IS the
--     service role — so a `reviewed_by` column would only ever hold one value.
--   * No enforcement side effects. Transitioning a report to `actioned` does not disable a profile,
--     hide a post, or notify anyone. Enforcement stays a separate, explicit act
--     (docs/MODERATION_PROCESS.md), because "actioned" describes the operator's decision, not a
--     state the database can carry out on its own.
--   * No read RPC. `public.reports` has exactly one policy, `reports_select_own`
--     (20260101000700_rls_policies.sql:74), and the operator reads the queue in the Supabase
--     dashboard, where they are the project owner and RLS does not constrain them. Adding an
--     admin-read RPC would create a privileged read path that has to be defended; the dashboard
--     already works.
--
-- `reviewing` deliberately does NOT stamp `reviewed_at`, and CLEARS it if it was already set.
-- `reviewed_at` is the retention clock's zero point, and `reviewing` means the review has STARTED,
-- not concluded. Stamping it there would start the 18-month clock when triage opened, so a report
-- that took three months to resolve would be destroyed 15 months after its resolution rather than
-- 18 — quietly shortening the published retention period, in the direction that loses evidence. It
-- also keeps `status in ('actioned','dismissed') ⇔ reviewed_at is not null` true, which is what the
-- report_reviewed_at_matches_status constraint enforces and what makes the purge's predicate
-- meaningful. The cost is that "when did triage start" is not recorded anywhere; it is not worth a
-- column, and reviewed_at is the wrong column for it.

create or replace function public.review_report(
  p_report_id uuid,
  p_status public.report_status
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prev public.report_status;
  v_prev_reviewed timestamptz;
  v_reviewed timestamptz;
begin
  -- Checked before the row is read so a bad status never depends on a report existing.
  if p_status is null then
    raise exception 'review_report: a target status is required (reviewing, actioned or dismissed)'
      using errcode = '22023';
  end if;
  if p_status = 'open' then
    raise exception 'review_report: open is a report''s initial state, not a review outcome'
      using errcode = '22023';
  end if;

  -- for update: two dashboard tabs reviewing the same report must serialise rather than race one
  -- outcome over the other.
  select status, reviewed_at into v_prev, v_prev_reviewed
    from public.reports
   where id = p_report_id
     for update;

  if not found then
    raise exception 'review_report: no report with id %', p_report_id
      using errcode = 'P0002';
  end if;

  v_reviewed := case
    -- Review re-opened: there is no conclusion time any more, and the retention clock must stop.
    when p_status = 'reviewing' then null
    -- Re-running the same outcome is idempotent and must NOT restart the 18-month clock. Changing
    -- the outcome (actioned -> dismissed) is a new conclusion and does re-stamp.
    when p_status = v_prev and v_prev_reviewed is not null then v_prev_reviewed
    else now()
  end;

  update public.reports
     set status = p_status,
         reviewed_at = v_reviewed
   where id = p_report_id;

  return jsonb_build_object(
    'report_id', p_report_id,
    'previous_status', v_prev,
    'status', p_status,
    'reviewed_at', v_reviewed
  );
end;
$$;

comment on function public.review_report(uuid, public.report_status) is
  'Service-role-only moderation transition: sets reports.status and stamps reviewed_at for '
  'actioned/dismissed. Rejects a transition to open. ''reviewing'' clears reviewed_at because that '
  'column is the retention clock, not a triage-started marker. See docs/MODERATION_PROCESS.md.';

-- Maintenance surface, exactly like the retention purges (20260812000400:116-123) and
-- prune_rate_limit_events (20260101000600_security_helpers.sql:140): no client role may transition a
-- report. The revoke is the guard that matters here — `authenticated` has table-level DML on
-- public.reports in some environments (the local test shim grants it in _shim_grants.sql, and RLS,
-- not privilege, is what stops a direct UPDATE), so the suite asserts the FUNCTION privilege rather
-- than trusting that a failed call means a working revoke.
revoke all on function public.review_report(uuid, public.report_status) from public, anon, authenticated;

-- Explicit rather than relying on the platform's default grants: this function is only useful to the
-- service role, and stating that makes it assertable. The documented operator workflow runs it in
-- the dashboard SQL editor as the table owner, which needs no grant at all; this grant is what lets
-- a scheduled job or a service-key call work.
grant execute on function public.review_report(uuid, public.report_status) to service_role;

-- 20260101000900_grants.sql:7 grants EXECUTE on every function in `public` to `authenticated`, which
-- swept up both trigger functions added with the reports table in 20260101000300_social_tables.sql.
-- Same treatment as set_updated_at and handle_new_user there. (Triggers do not re-check EXECUTE when
-- they fire, so this changes nothing about stamping or erasing; it keeps the callable surface honest.
-- The three report_*_key functions are deliberately NOT revoked — see the note above them in
-- 20260101000300: the derivation is public and unsalted, so revoking would protect nothing.)
revoke execute on function public.reports_stamp_party_keys() from authenticated;
revoke execute on function public.reports_erase_reporter_details() from authenticated;
