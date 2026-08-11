-- CheekyPint: export_my_data() — DSGVO Art. 15 (access) / Art. 20 (portability).
--
-- The app can delete a user's account but, before this migration, gave them no way to obtain
-- a copy of their own data. This adds a single caller-scoped read RPC returning one JSON
-- document: profile, privacy settings, pint entries, authored posts (+ their comment mentions),
-- cheers given, friendships, blocks placed, reports filed, pub preferences, hosted sessions,
-- session memberships, and Nudges sent/received.
--
-- Why SECURITY DEFINER is required and also the single biggest risk here: public.posts,
-- public.post_comments, public.post_cheers, public.comment_mentions and public.nudges are
-- RLS-enabled with NO policies (or, for nudges, a policy-free table entirely) — a direct
-- `select` on them returns nothing even for the caller. This function is deliberately granted
-- the owner's privileges so it CAN read across that wall — which is exactly why every single
-- subquery below is filtered to auth.uid(). A collection missing that filter does not merely
-- over-return: it hands one user another user's diary, posts, or comments. Every collection is
-- commented with the column that scopes it.
--
-- Bounded work (fix round 1, I5): enforce_rate_limit's own INSERT lives in the same
-- transaction as this function's read work. If the transaction never commits — the client
-- disconnects mid-response, or anything downstream errors — that insert rolls back too, so a
-- failed or abandoned export consumes NO quota. Every other caller of enforce_rate_limit is a
-- cheap single-row write for which that's a non-issue; this function scans up to a dozen
-- tables and can build a multi-MB document, so "send request, disconnect, repeat" is an
-- unbounded work amplifier that the rate limit alone does not stop. plpgsql cannot durably
-- record quota usage outside its own transaction without an extension (dblink/autonomous
-- transactions), which we deliberately do not reach for here. Instead each collection below is
-- capped at v_cap (10,000 rows — far beyond any real user) and the top-level `truncated` flag
-- is set true if ANY collection hit that cap, bounding the cost of even an unbounded retry
-- loop to a fixed amount of work per call. A `truncated: true` export is honest but incomplete;
-- ops should treat it as a signal to serve that data subject's Art. 15 request manually rather
-- than silently ship a partial file.
--
-- Judgement calls (reasoned in full in task-4-report.md):
--
-- 1. Soft-deleted rows ARE included for pint_entries, posts and comments. They are still the
--    caller's own data until a retention job purges them (purge_soft_deleted_posts /
--    _comments / _pint_entries, 20260812000400_retention_purges.sql), and Art. 15 access does
--    not lapse just because the user pressed delete. `deleted_at` (null when live) is exported
--    on every such row and doubles as the "is this deleted" flag — no separate boolean needed.
--
-- 2. comment_mentions: only "people I mentioned" is surfaced, nested as `mentioned_user_ids`
--    inside each of the caller's OWN comments — entirely the caller's authored content (they
--    already know who they @-mentioned). "Comments where I was mentioned" is deliberately NOT
--    included: making that useful would require surfacing another author's comment_id and body
--    inside THIS caller's export, which is that author's data, not the caller's.
--
-- 3. `reports` the caller FILED are included, with `reported_user_id` omitted (fix round 1,
--    reviewer note). Revised from the original cut: `details` is free text the CALLER wrote —
--    unambiguously their own data — and we already export other third-party identifiers
--    attached to a caller action (`blocks.blocked_id`, `comments.mentioned_user_ids`), so
--    omitting the whole table was inconsistent. The proportionate Art. 15(4) remedy for "shall
--    not adversely affect the rights of others" is redacting the one column that identifies
--    who was accused (`reported_user_id`), not withholding the caller's own report entirely.
--    `post_id`/`comment_id` are kept (they identify WHAT was reported, not WHO — same
--    footing as a friendship or block row naming a counterparty).
--
-- `blocks` follows the app's own existing convention (get_blocked_users(),
-- 20260101000800_rpc_social.sql, and the blocks_select_own RLS policy,
-- 20260101000700_rls_policies.sql: "You can see who YOU blocked (not who blocked you)"): only
-- blocks the caller placed (blocker_id = auth.uid()) are exported, not blocks placed against
-- them by someone else.
--
-- `friend_tokens` is DELIBERATELY EXCLUDED (fix round 1, I6). It is a live invite credential —
-- its hash resolves to a real, currently-usable QR/deep-link token. Writing that into a file
-- the user downloads, stores, and may email or paste around is a security regression, not
-- portability; the raw token itself is never persisted server-side in the first place
-- (regenerate_friend_token, 20260101000800_rpc_social.sql), so there is nothing meaningfully
-- "portable" here beyond a hash that only enables impersonation risk if handled carelessly.
--
-- `pub_sessions.join_token_hash` is likewise omitted from the exported session objects for the
-- same reason, even though it is only a hash: it has no portability value (the caller can't
-- reconstruct the raw join link from it) and no reason to leave the database in a file.
--
-- Known app-level gap this export surfaces but does NOT fix (see task-4-report.md): Nudges the
-- caller SENT have no read path anywhere else in the app — public.nudges is revoked with no
-- policies, and get_received_nudges() only ever reads the recipient side. Until now a user's
-- own sent-Nudge history was unrecoverable by design; `nudges_sent` below is the first (and
-- only) way to see it. That's an Art. 15 gap in the app that predates this migration, noted
-- here rather than silently patched over by this export existing.

create or replace function public.export_my_data()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_cap constant int := 10000;
  v_truncated boolean := false;
  v_total int;
  v_profile jsonb;
  v_privacy_settings jsonb;
  v_pint_entries jsonb;
  v_posts jsonb;
  v_comments jsonb;
  v_cheers_given jsonb;
  v_friends jsonb;
  v_blocks jsonb;
  v_reports jsonb;
  v_user_pub_preferences jsonb;
  v_pub_sessions jsonb;
  v_session_members jsonb;
  v_nudges_sent jsonb;
  v_nudges_received jsonb;
  v_result jsonb;
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;
  perform public.enforce_rate_limit('data_export', 5, interval '24 hours');

  -- profile: scoped by id = caller's own uid. One row, the caller's own. Unbounded by
  -- definition (a profile is one row), so no cap applies.
  select jsonb_build_object(
    'id', p.id,
    'display_name', p.display_name,
    'username', p.username,
    'bio', p.bio,
    'avatar_path', p.avatar_path,
    'city', p.city,
    'country_code', p.country_code,
    'legal_age_confirmed_at', p.legal_age_confirmed_at,
    'timezone', p.timezone,
    'locale', p.locale,
    'created_at', p.created_at,
    'updated_at', p.updated_at,
    'deleted_at', p.deleted_at
  ) into v_profile
  from public.profiles p
  where p.id = v_uid;

  -- privacy_settings: scoped by user_id = caller's own uid. One row, the caller's own.
  -- `user_id` is exported (fix round 1, I4) so the object is structurally self-verifying —
  -- previously nothing in the payload could confirm whose nine visibility switches these were.
  select jsonb_build_object(
    'user_id', s.user_id,
    'profile_visibility', s.profile_visibility,
    'avatar_visibility', s.avatar_visibility,
    'city_visibility', s.city_visibility,
    'session_total_visibility', s.session_total_visibility,
    'weekly_total_visibility', s.weekly_total_visibility,
    'monthly_total_visibility', s.monthly_total_visibility,
    'yearly_total_visibility', s.yearly_total_visibility,
    'favourite_pubs_visibility', s.favourite_pubs_visibility,
    'shared_sessions_visibility', s.shared_sessions_visibility,
    'created_at', s.created_at,
    'updated_at', s.updated_at
  ) into v_privacy_settings
  from public.privacy_settings s
  where s.user_id = v_uid;

  -- pint_entries: scoped by user_id = caller's own uid. Includes soft-deleted rows
  -- (deleted_at not null) — see judgement call 1 above.
  select count(*) into v_total from public.pint_entries e where e.user_id = v_uid;
  if v_total > v_cap then v_truncated := true; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', e.id,
    'user_id', e.user_id,
    'pub_id', e.pub_id,
    'session_id', e.session_id,
    'occurred_at', e.occurred_at,
    'serving_type', e.serving_type,
    'volume_ml', e.volume_ml,
    'alcohol_free', e.alcohol_free,
    'private_note', e.private_note,
    'source', e.source,
    'flagged_high_frequency', e.flagged_high_frequency,
    'created_at', e.created_at,
    'updated_at', e.updated_at,
    'deleted_at', e.deleted_at
  ) order by e.occurred_at desc), '[]'::jsonb) into v_pint_entries
  from (
    select * from public.pint_entries e where e.user_id = v_uid
    order by e.occurred_at desc limit v_cap
  ) e;

  -- posts: scoped by author_id = caller's own uid. Includes soft-deleted rows — see judgement
  -- call 1. RLS on public.posts has no policies, so only this SECURITY DEFINER path can read
  -- them at all (20260811000100_feed_tables.sql:92-101).
  select count(*) into v_total from public.posts po where po.author_id = v_uid;
  if v_total > v_cap then v_truncated := true; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', po.id,
    'author_id', po.author_id,
    'body', po.body,
    'image_path', po.image_path,
    'place_label', po.place_label,
    'pub_id', po.pub_id,
    'created_at', po.created_at,
    'deleted_at', po.deleted_at
  ) order by po.created_at desc), '[]'::jsonb) into v_posts
  from (
    select * from public.posts po where po.author_id = v_uid
    order by po.created_at desc limit v_cap
  ) po;

  -- comments: scoped by author_id = caller's own uid. Includes soft-deleted rows — see
  -- judgement call 1. mentioned_user_ids is drawn from comment_mentions rows correlated to
  -- THIS comment only (m.comment_id = c.id) — the comment_id already belongs to the caller
  -- (see judgement call 2). Not capped independently: it can only ever hold as many entries as
  -- the caller has friends, which is bounded in practice.
  select count(*) into v_total from public.post_comments c where c.author_id = v_uid;
  if v_total > v_cap then v_truncated := true; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', c.id,
    'post_id', c.post_id,
    'author_id', c.author_id,
    'body', c.body,
    'created_at', c.created_at,
    'deleted_at', c.deleted_at,
    'mentioned_user_ids', (
      select coalesce(jsonb_agg(m.mentioned_user_id), '[]'::jsonb)
      from public.comment_mentions m
      where m.comment_id = c.id
    )
  ) order by c.created_at desc), '[]'::jsonb) into v_comments
  from (
    select * from public.post_comments c where c.author_id = v_uid
    order by c.created_at desc limit v_cap
  ) c;

  -- cheers_given: scoped by user_id = caller's own uid — the caller's own reactions, not who
  -- cheered the caller's posts (that distinction is the entire point of this predicate).
  select count(*) into v_total from public.post_cheers pc where pc.user_id = v_uid;
  if v_total > v_cap then v_truncated := true; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'post_id', pc.post_id,
    'user_id', pc.user_id,
    'created_at', pc.created_at
  ) order by pc.created_at desc), '[]'::jsonb) into v_cheers_given
  from (
    select * from public.post_cheers pc where pc.user_id = v_uid
    order by pc.created_at desc limit v_cap
  ) pc;

  -- friends: scoped by (requester_id = caller's own uid OR addressee_id = caller's own uid) —
  -- every friendship row the caller is a party to, in either direction. The counterparty's uid
  -- is inherent to a friendship record itself, not a leak.
  select count(*) into v_total
  from public.friendships f where f.requester_id = v_uid or f.addressee_id = v_uid;
  if v_total > v_cap then v_truncated := true; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', f.id,
    'requester_id', f.requester_id,
    'addressee_id', f.addressee_id,
    'status', f.status,
    'requested_at', f.requested_at,
    'responded_at', f.responded_at,
    'updated_at', f.updated_at
  ) order by f.requested_at desc), '[]'::jsonb) into v_friends
  from (
    select * from public.friendships f where f.requester_id = v_uid or f.addressee_id = v_uid
    order by f.requested_at desc limit v_cap
  ) f;

  -- blocks: scoped by blocker_id = caller's own uid — blocks the caller PLACED only, never
  -- blocks placed against them. Matches the app's own blocks_select_own RLS policy and
  -- get_blocked_users() (20260101000700_rls_policies.sql, 20260101000800_rpc_social.sql).
  select count(*) into v_total from public.blocks b where b.blocker_id = v_uid;
  if v_total > v_cap then v_truncated := true; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'blocker_id', b.blocker_id,
    'blocked_id', b.blocked_id,
    'created_at', b.created_at
  ) order by b.created_at desc), '[]'::jsonb) into v_blocks
  from (
    select * from public.blocks b where b.blocker_id = v_uid
    order by b.created_at desc limit v_cap
  ) b;

  -- reports: scoped by reporter_id = caller's own uid — reports the caller FILED, never
  -- reports filed against them. `reported_user_id` is deliberately omitted — see judgement
  -- call 3 above.
  select count(*) into v_total from public.reports r where r.reporter_id = v_uid;
  if v_total > v_cap then v_truncated := true; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', r.id,
    'reporter_id', r.reporter_id,
    'category', r.category,
    'details', r.details,
    'status', r.status,
    'post_id', r.post_id,
    'comment_id', r.comment_id,
    'created_at', r.created_at,
    'reviewed_at', r.reviewed_at
  ) order by r.created_at desc), '[]'::jsonb) into v_reports
  from (
    select * from public.reports r where r.reporter_id = v_uid
    order by r.created_at desc limit v_cap
  ) r;

  -- user_pub_preferences: scoped by user_id = caller's own uid.
  select count(*) into v_total from public.user_pub_preferences up where up.user_id = v_uid;
  if v_total > v_cap then v_truncated := true; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id', up.user_id,
    'pub_id', up.pub_id,
    'hidden_from_favourites', up.hidden_from_favourites,
    'created_at', up.created_at,
    'updated_at', up.updated_at
  ) order by up.created_at desc), '[]'::jsonb) into v_user_pub_preferences
  from (
    select * from public.user_pub_preferences up where up.user_id = v_uid
    order by up.created_at desc limit v_cap
  ) up;

  -- pub_sessions: scoped by host_user_id = caller's own uid — sessions the caller HOSTS, not
  -- every session they've ever attended as a member (that's session_members below).
  -- join_token_hash is omitted — see the header note above.
  select count(*) into v_total from public.pub_sessions ps where ps.host_user_id = v_uid;
  if v_total > v_cap then v_truncated := true; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', ps.id,
    'pub_id', ps.pub_id,
    'host_user_id', ps.host_user_id,
    'name', ps.name,
    'status', ps.status,
    'started_at', ps.started_at,
    'ended_at', ps.ended_at,
    'created_at', ps.created_at,
    'updated_at', ps.updated_at
  ) order by ps.started_at desc), '[]'::jsonb) into v_pub_sessions
  from (
    select * from public.pub_sessions ps where ps.host_user_id = v_uid
    order by ps.started_at desc limit v_cap
  ) ps;

  -- session_members: scoped by user_id = caller's own uid — the caller's own membership rows,
  -- across every session they've joined (hosted or not).
  select count(*) into v_total from public.session_members sm where sm.user_id = v_uid;
  if v_total > v_cap then v_truncated := true; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'session_id', sm.session_id,
    'user_id', sm.user_id,
    'role', sm.role,
    'joined_at', sm.joined_at,
    'left_at', sm.left_at
  ) order by sm.joined_at desc), '[]'::jsonb) into v_session_members
  from (
    select * from public.session_members sm where sm.user_id = v_uid
    order by sm.joined_at desc limit v_cap
  ) sm;

  -- nudges_sent: scoped by sender_id = caller's own uid. See the header note: this is
  -- currently the ONLY read path in the entire app for a user's own sent-Nudge history.
  select count(*) into v_total from public.nudges n where n.sender_id = v_uid;
  if v_total > v_cap then v_truncated := true; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', n.id,
    'sender_id', n.sender_id,
    'recipient_id', n.recipient_id,
    'created_at', n.created_at,
    'acknowledged_at', n.acknowledged_at
  ) order by n.created_at desc), '[]'::jsonb) into v_nudges_sent
  from (
    select * from public.nudges n where n.sender_id = v_uid
    order by n.created_at desc limit v_cap
  ) n;

  -- nudges_received: scoped by recipient_id = caller's own uid. Unlike get_received_nudges()
  -- (20260803000000_nudges.sql), this includes already-acknowledged Nudges too — Art. 15 access
  -- to your own history doesn't expire just because you replied.
  select count(*) into v_total from public.nudges n where n.recipient_id = v_uid;
  if v_total > v_cap then v_truncated := true; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', n.id,
    'sender_id', n.sender_id,
    'recipient_id', n.recipient_id,
    'created_at', n.created_at,
    'acknowledged_at', n.acknowledged_at
  ) order by n.created_at desc), '[]'::jsonb) into v_nudges_received
  from (
    select * from public.nudges n where n.recipient_id = v_uid
    order by n.created_at desc limit v_cap
  ) n;

  select jsonb_build_object(
    'exported_at', now(),
    'truncated', v_truncated,
    'profile', v_profile,
    'privacy_settings', v_privacy_settings,
    'pint_entries', v_pint_entries,
    'posts', v_posts,
    'comments', v_comments,
    'cheers_given', v_cheers_given,
    'friends', v_friends,
    'blocks', v_blocks,
    'reports', v_reports,
    'user_pub_preferences', v_user_pub_preferences,
    'pub_sessions', v_pub_sessions,
    'session_members', v_session_members,
    'nudges_sent', v_nudges_sent,
    'nudges_received', v_nudges_received
  ) into v_result;

  return v_result;
end;
$$;

comment on function public.export_my_data() is
  'DSGVO Art. 15/20 self-service export: one caller-scoped JSON document of the caller''s own profile, privacy settings, pint entries, posts, comments (+ mentions made), cheers given, friendships, blocks placed, reports filed (reported_user_id redacted), pub preferences, hosted sessions, session memberships, and Nudges sent/received. Every subquery filters to auth.uid(); every collection is capped at 10,000 rows with a top-level truncated flag. friend_tokens is deliberately excluded. See migration header for the full per-key scoping rationale.';

revoke all on function public.export_my_data() from public, anon;
grant execute on function public.export_my_data() to authenticated;
