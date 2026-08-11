-- CheekyPint: export_my_data() — DSGVO Art. 15 (access) / Art. 20 (portability).
--
-- The app can delete a user's account but, before this migration, gave them no way to obtain
-- a copy of their own data. This adds a single caller-scoped read RPC returning one JSON
-- document: profile, privacy settings, pint entries, authored posts, authored comments,
-- cheers given, friendships and blocks.
--
-- Why SECURITY DEFINER is required and also the single biggest risk here: public.posts,
-- public.post_comments, public.post_cheers and public.comment_mentions are RLS-enabled with
-- NO policies (20260811000100_feed_tables.sql:92-101) — a direct `select` on them returns
-- nothing even for their own author. This function is deliberately granted the owner's
-- privileges so it CAN read across that wall — which is exactly why every single subquery
-- below is filtered to auth.uid(). A collection missing that filter does not merely
-- over-return: it hands one user another user's diary, posts, or comments. Every collection
-- is commented with the column that scopes it.
--
-- Judgement calls (reasoned in full in task-4-report.md):
--
-- 1. Soft-deleted rows ARE included for pint_entries, posts and comments. They are still the
--    caller's own data until a retention job purges them (purge_soft_deleted_posts /
--    _comments / _pint_entries, 20260812000400_retention_purges.sql), and Art. 15 access
--    does not lapse just because the user pressed delete. `deleted_at` (null when live) is
--    exported on every such row and doubles as the "is this deleted" flag — no separate
--    boolean is needed.
--
-- 2. comment_mentions: only "people I mentioned" is surfaced, nested as `mentioned_user_ids`
--    inside each of the caller's OWN comments — that is entirely the caller's authored
--    content (they already know who they @-mentioned). "Comments where I was mentioned" is
--    deliberately NOT included: making that useful would require surfacing another author's
--    comment_id and body inside THIS caller's export, which is that author's data, not the
--    caller's, and is outside the documented interface for this function.
--
-- 3. `reports` the caller filed are NOT included. They are accusations about a third party
--    (reported_user_id, category, free-text details) rather than data belonging to the
--    reporter, and Art. 15(4) GDPR is explicit that the right of access "shall not adversely
--    affect the rights and freedoms of others". The reporter already has an existing direct
--    read path to their own filed reports via the `reports_select_own` RLS policy
--    (20260101000700_rls_policies.sql) — this decision withholds them from THIS bulk/portable
--    export, not from the app entirely.
--
-- `blocks` follows the app's own existing convention (get_blocked_users(),
-- 20260101000800_rpc_social.sql, and the blocks_select_own RLS policy,
-- 20260101000700_rls_policies.sql: "You can see who YOU blocked (not who blocked you)"): only
-- blocks the caller placed (blocker_id = auth.uid()) are exported, not blocks placed against
-- them by someone else.

create or replace function public.export_my_data()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_result jsonb;
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;
  perform public.enforce_rate_limit('data_export', 5, interval '24 hours');

  select jsonb_build_object(
    'exported_at', now(),

    -- profile: scoped by id = caller's own uid. One row, the caller's own.
    'profile', (
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
      )
      from public.profiles p
      where p.id = v_uid
    ),

    -- privacy_settings: scoped by user_id = caller's own uid. One row, the caller's own.
    'privacy_settings', (
      select jsonb_build_object(
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
      )
      from public.privacy_settings s
      where s.user_id = v_uid
    ),

    -- pint_entries: scoped by user_id = caller's own uid. Includes soft-deleted rows
    -- (deleted_at not null) — see judgement call 1 above.
    'pint_entries', (
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
      ) order by e.occurred_at desc), '[]'::jsonb)
      from public.pint_entries e
      where e.user_id = v_uid
    ),

    -- posts: scoped by author_id = caller's own uid. Includes soft-deleted rows — see
    -- judgement call 1. RLS on public.posts has no policies, so only this SECURITY DEFINER
    -- path can read them at all (20260811000100_feed_tables.sql:92-101).
    'posts', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', po.id,
        'author_id', po.author_id,
        'body', po.body,
        'image_path', po.image_path,
        'place_label', po.place_label,
        'pub_id', po.pub_id,
        'created_at', po.created_at,
        'deleted_at', po.deleted_at
      ) order by po.created_at desc), '[]'::jsonb)
      from public.posts po
      where po.author_id = v_uid
    ),

    -- comments: scoped by author_id = caller's own uid. Includes soft-deleted rows — see
    -- judgement call 1. mentioned_user_ids is drawn from comment_mentions rows for THIS
    -- comment only, i.e. the comment_id already belongs to the caller (see judgement call 2).
    'comments', (
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
      ) order by c.created_at desc), '[]'::jsonb)
      from public.post_comments c
      where c.author_id = v_uid
    ),

    -- cheers_given: scoped by user_id = caller's own uid — the caller's own reactions, not
    -- who cheered the caller's posts.
    'cheers_given', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'post_id', pc.post_id,
        'user_id', pc.user_id,
        'created_at', pc.created_at
      ) order by pc.created_at desc), '[]'::jsonb)
      from public.post_cheers pc
      where pc.user_id = v_uid
    ),

    -- friends: scoped by (requester_id = caller's own uid OR addressee_id = caller's own
    -- uid) — every friendship row the caller is a party to, in either direction. The
    -- counterparty's uid is inherent to a friendship record itself, not a leak.
    'friends', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', f.id,
        'requester_id', f.requester_id,
        'addressee_id', f.addressee_id,
        'status', f.status,
        'requested_at', f.requested_at,
        'responded_at', f.responded_at,
        'updated_at', f.updated_at
      ) order by f.requested_at desc), '[]'::jsonb)
      from public.friendships f
      where f.requester_id = v_uid or f.addressee_id = v_uid
    ),

    -- blocks: scoped by blocker_id = caller's own uid — blocks the caller PLACED only, never
    -- blocks placed against them. Matches the app's own blocks_select_own RLS policy and
    -- get_blocked_users() (20260101000700_rls_policies.sql, 20260101000800_rpc_social.sql).
    'blocks', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'blocker_id', b.blocker_id,
        'blocked_id', b.blocked_id,
        'created_at', b.created_at
      ) order by b.created_at desc), '[]'::jsonb)
      from public.blocks b
      where b.blocker_id = v_uid
    )
  )
  into v_result;

  return v_result;
end;
$$;

comment on function public.export_my_data() is
  'DSGVO Art. 15/20 self-service export: one caller-scoped JSON document of the caller''s own profile, privacy settings, pint entries, posts, comments, cheers given, friendships and blocks placed. Every subquery filters to auth.uid(); see migration header for the full per-key scoping rationale.';

revoke all on function public.export_my_data() from public, anon;
grant execute on function public.export_my_data() to authenticated;
