-- CheekyPint: reporting feed content. Mirrors public.report_user's shape and rate-limit action
-- so the moderation queue stays one uniform surface.
--
-- p_details is free text that a human moderator reads, so it goes through
-- public.strip_ugc_control_chars before storage, exactly like create_post's body/place label and
-- add_comment's body. Without it a bidi override (U+202E) or a zero-width run landed verbatim in
-- reports.details, letting a reporter scramble or spoof what the moderator sees — in the one
-- column whose whole purpose is to be read by a person deciding whether text is abusive.
-- left(..., 1000) alone bounded the length but not the content.

create or replace function public.report_post(
  p_post_id uuid,
  p_category public.report_category,
  p_details text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_author uuid;
  v_row public.reports;
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;
  if not public.can_view_post(v_uid, p_post_id) then
    raise exception 'Post not available' using errcode = 'P0002';
  end if;

  select author_id into v_author from public.posts where id = p_post_id;
  if v_author = v_uid then
    raise exception 'Cannot report yourself' using errcode = '22023';
  end if;

  perform public.enforce_rate_limit('report', 20, interval '1 hour');

  insert into public.reports (reporter_id, reported_user_id, category, details, post_id)
  values (v_uid, v_author, p_category,
          left(btrim(public.strip_ugc_control_chars(p_details)), 1000), p_post_id)
  returning * into v_row;

  return jsonb_build_object('report_id', v_row.id, 'status', v_row.status);
end;
$$;

create or replace function public.report_comment(
  p_comment_id uuid,
  p_category public.report_category,
  p_details text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_author uuid;
  v_post uuid;
  v_row public.reports;
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;

  select author_id, post_id into v_author, v_post
    from public.post_comments
   where id = p_comment_id and deleted_at is null;

  if v_author is null or not public.can_view_post(v_uid, v_post) then
    raise exception 'Comment not available' using errcode = 'P0002';
  end if;
  if v_author = v_uid then
    raise exception 'Cannot report yourself' using errcode = '22023';
  end if;

  perform public.enforce_rate_limit('report', 20, interval '1 hour');

  insert into public.reports (reporter_id, reported_user_id, category, details, comment_id)
  values (v_uid, v_author, p_category,
          left(btrim(public.strip_ugc_control_chars(p_details)), 1000), p_comment_id)
  returning * into v_row;

  return jsonb_build_object('report_id', v_row.id, 'status', v_row.status);
end;
$$;

revoke all on function public.report_post(uuid, public.report_category, text) from public, anon;
revoke all on function public.report_comment(uuid, public.report_category, text) from public, anon;

grant execute on function public.report_post(uuid, public.report_category, text) to authenticated;
grant execute on function public.report_comment(uuid, public.report_category, text) to authenticated;
