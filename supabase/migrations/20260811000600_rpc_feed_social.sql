-- CheekyPint: feed reactions, comments and mentions.
-- Every entry point re-checks that the caller can see the post — a post id is guessable enough
-- that visibility must be proven per call, not assumed from the client having one.

create or replace function public.can_view_post(p_uid uuid, p_post_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.posts p
     where p.id = p_post_id
       and p.deleted_at is null
       and (p.author_id = p_uid or public.is_accepted_friend(p_uid, p.author_id))
  );
$$;

create or replace function public.toggle_post_cheers(p_post_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_cheered boolean;
  v_count int;
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;
  if not public.can_view_post(v_uid, p_post_id) then
    raise exception 'Post not available' using errcode = 'P0002';
  end if;

  perform public.enforce_rate_limit('post_cheers', 200, interval '1 hour');

  delete from public.post_cheers where post_id = p_post_id and user_id = v_uid;
  if found then
    v_cheered := false;
  else
    insert into public.post_cheers (post_id, user_id) values (p_post_id, v_uid);
    v_cheered := true;
  end if;

  select count(*)::int into v_count from public.post_cheers where post_id = p_post_id;
  return jsonb_build_object('cheered', v_cheered, 'cheers_count', v_count);
end;
$$;

create or replace function public.add_comment(
  p_post_id uuid,
  p_body text,
  p_mentions uuid[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_body text;
  v_row public.post_comments;
  v_mention uuid;
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;
  if not public.can_view_post(v_uid, p_post_id) then
    raise exception 'Post not available' using errcode = 'P0002';
  end if;

  perform public.enforce_rate_limit('post_comment', 60, interval '1 hour');

  v_body := nullif(btrim(public.strip_ugc_control_chars(p_body)), '');
  if v_body is null then
    raise exception 'A comment needs some words' using errcode = '22023';
  end if;

  -- You can only mention people you are actually friends with; this closes the obvious
  -- harassment vector of tagging strangers into a thread.
  foreach v_mention in array coalesce(p_mentions, array[]::uuid[]) loop
    if v_mention <> v_uid and not public.is_accepted_friend(v_uid, v_mention) then
      raise exception 'Can only mention friends' using errcode = 'P0002';
    end if;
  end loop;

  insert into public.post_comments (post_id, author_id, body)
  values (p_post_id, v_uid, left(v_body, 280))
  returning * into v_row;

  insert into public.comment_mentions (comment_id, mentioned_user_id)
  select v_row.id, m
    from unnest(coalesce(p_mentions, array[]::uuid[])) as m
   where m <> v_uid
  on conflict do nothing;

  return jsonb_build_object('comment_id', v_row.id);
end;
$$;

create or replace function public.delete_comment(p_comment_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;

  update public.post_comments
     set deleted_at = now()
   where id = p_comment_id
     and author_id = v_uid
     and deleted_at is null;

  if not found then
    raise exception 'Comment not available' using errcode = 'P0002';
  end if;
end;
$$;

create or replace function public.post_comments_page(
  p_post_id uuid,
  p_before timestamptz default null,
  p_limit int default 30
)
returns table (
  comment_id uuid,
  author_id uuid,
  display_name text,
  avatar_path text,
  body text,
  created_at timestamptz,
  mentioned_user_ids uuid[]
)
language sql
stable
security definer
set search_path = ''
as $$
  select c.id,
         c.author_id,
         pr.display_name,
         -- Mirror the established avatar-visibility gate (see feed_page in
         -- 20260811000500_rpc_feed_posts.sql:133-134, which itself mirrors
         -- get_friend_leaderboard in 20260101000800_rpc_social.sql:247): self always sees it;
         -- a friend only when the owner has avatar_visibility = 'friends'. Returning it
         -- unconditionally would leak an avatar its owner hid from friends.
         case when c.author_id = auth.uid() or ps.avatar_visibility = 'friends'
              then pr.avatar_path end,
         c.body,
         c.created_at,
         coalesce(
           (select array_agg(m.mentioned_user_id)
              from public.comment_mentions m
             where m.comment_id = c.id),
           array[]::uuid[]
         )
    from public.post_comments c
    join public.profiles pr on pr.id = c.author_id
    join public.privacy_settings ps on ps.user_id = c.author_id
   where c.post_id = p_post_id
     and c.deleted_at is null
     and pr.deleted_at is null
     and public.can_view_post(auth.uid(), p_post_id)
     and not public.is_blocked(auth.uid(), c.author_id)
     and c.created_at < coalesce(p_before, now() + interval '1 second')
   order by c.created_at
   limit least(greatest(coalesce(p_limit, 30), 1), 100);
$$;

revoke all on function public.can_view_post(uuid, uuid) from public, anon;
revoke all on function public.toggle_post_cheers(uuid) from public, anon;
revoke all on function public.add_comment(uuid, text, uuid[]) from public, anon;
revoke all on function public.delete_comment(uuid) from public, anon;
revoke all on function public.post_comments_page(uuid, timestamptz, int) from public, anon;

grant execute on function public.can_view_post(uuid, uuid) to authenticated;
grant execute on function public.toggle_post_cheers(uuid) to authenticated;
grant execute on function public.add_comment(uuid, text, uuid[]) to authenticated;
grant execute on function public.delete_comment(uuid) to authenticated;
grant execute on function public.post_comments_page(uuid, timestamptz, int) to authenticated;
