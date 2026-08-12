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

  perform public.enforce_rate_limit('cheers_toggle', 120, interval '1 hour');

  -- The INSERT is the arbiter, not a preceding DELETE-then-branch: two concurrent un-cheer taps
  -- under READ COMMITTED could otherwise both find nothing to delete and both insert, leaving a
  -- cheered row after two "uncheer" taps; two concurrent cheer taps could both attempt the
  -- insert and one would die on the post_cheers_pkey unique violation with a raw constraint-name
  -- error instead of a handled outcome. ON CONFLICT DO NOTHING makes the insert either succeed
  -- (this call turned it on) or no-op (someone already had it on, so this call turns it off) —
  -- every interleaving converges instead of erroring, which matters because the client does an
  -- optimistic toggle and rapid double-taps are the expected case, not an edge case.
  with ins as (
    insert into public.post_cheers (post_id, user_id)
    values (p_post_id, v_uid)
    on conflict (post_id, user_id) do nothing
    returning 1
  )
  select exists (select 1 from ins) into v_cheered;

  if not v_cheered then
    delete from public.post_cheers where post_id = p_post_id and user_id = v_uid;
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
  v_mention_ids uuid[] := array[]::uuid[];
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;
  if not public.can_view_post(v_uid, p_post_id) then
    raise exception 'Post not available' using errcode = 'P0002';
  end if;

  perform public.enforce_rate_limit('post_comment', 60, interval '1 hour');

  -- Multi-line, like posts.body: the composer is `axis: .vertical` and PostCommentsSheet renders
  -- the comment through `highlightedBody`, a per-character mask that preserves every character it is
  -- given, newlines included.
  v_body := nullif(public.strip_ugc_control_chars_multiline(p_body), '');
  if v_body is null then
    raise exception 'A comment needs some words' using errcode = '22023';
  end if;

  -- You can only mention people you are actually friends with; this closes the obvious
  -- harassment vector of tagging strangers into a thread, and the rejection here is safe to
  -- surface because the commenter already knows their own friend list.
  --
  -- A friend of the COMMENTER is not automatically able to see this POST — e.g. the post author
  -- blocked them. That second case must NOT raise: the commenter is not necessarily aware of the
  -- private relationship (a block, or a visibility setting) between the mention target and the
  -- post's author, so a distinguishable rejection here would let the commenter probe up to 60
  -- friend/post pairs an hour and learn a fact about someone else's graph they have no business
  -- knowing. Instead, silently drop that target from the mention list — the comment itself still
  -- posts normally. Nothing is lost: mention notifications are an explicit spec non-goal, so a
  -- silently-omitted mention has no observable side effect for the dropped target either way.
  -- `is distinct from` (not `<>`) keeps a NULL array element from silently skipping this check.
  foreach v_mention in array coalesce(p_mentions, array[]::uuid[]) loop
    if v_mention is distinct from v_uid then
      if not public.is_accepted_friend(v_uid, v_mention) then
        raise exception 'Can only mention friends' using errcode = 'P0002';
      elsif public.can_view_post(v_mention, p_post_id) then
        v_mention_ids := array_append(v_mention_ids, v_mention);
      end if;
    end if;
  end loop;

  insert into public.post_comments (post_id, author_id, body)
  values (p_post_id, v_uid, left(v_body, 280))
  returning * into v_row;

  insert into public.comment_mentions (comment_id, mentioned_user_id)
  select v_row.id, m
    from unnest(v_mention_ids) as m
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

  perform public.enforce_rate_limit('comment_delete', 60, interval '1 hour');

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
  p_before_id uuid default null,
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
         -- The gate is about the COMMENTER's privacy choice and the VIEWER's relationship to
         -- the commenter — NOT to the post author. Comment authors here are friends of the
         -- post's author and need no relationship to the viewer (that's what can_view_post
         -- below already established), so unlike feed_page (whose row set is pre-restricted to
         -- the viewer's own friends, making avatar_visibility = 'friends' alone sufficient) this
         -- must separately check public.is_accepted_friend(auth.uid(), c.author_id). Without
         -- that check, any viewer who can merely see the THREAD (e.g. a mutual friend of the
         -- post's author who is a stranger to this particular commenter) would also see that
         -- commenter's avatar regardless of the commenter's own privacy setting.
         case when c.author_id = auth.uid()
                or (ps.avatar_visibility = 'friends'
                    and public.is_accepted_friend(auth.uid(), c.author_id))
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
     -- Compound keyset cursor, ascending (oldest-first is correct for a comment thread — unlike
     -- feed_page's newest-first). The cursor moves strictly forward in the SAME direction as the
     -- sort, i.e. "created_at, id) > cursor", not "<": a page ordered ASC that filtered with "<"
     -- would keep re-serving the oldest rows on every subsequent page and could never reach the
     -- newer end. Coalescing a missing p_before_id to the MINIMUM uuid (not the maximum, as
     -- feed_page does for its DESC order) keeps that same "incomplete cursor is inclusive, never
     -- lossy" property for this ascending sort: a caller that supplies p_before without
     -- p_before_id may re-see one already-shown row rather than silently skip past unseen ones.
     and (p_before is null
          or (c.created_at, c.id) > (p_before, coalesce(p_before_id, '00000000-0000-0000-0000-000000000000'::uuid)))
   order by c.created_at, c.id
   limit least(greatest(coalesce(p_limit, 30), 1), 100);
$$;

-- can_view_post is revoked from `authenticated` too, not just public/anon: it is a pure
-- visibility oracle with no rate limit or side effect, and every RPC above already calls it as
-- its owner from inside a SECURITY DEFINER function, where the call resolves against the
-- function owner's privileges regardless of what the calling role was granted directly —
-- exactly how enforce_rate_limit (also owner-only) already works from inside add_comment.
-- Granting it to `authenticated` would let any client probe arbitrary (uid, post_id) pairs
-- directly for no product reason.
revoke all on function public.can_view_post(uuid, uuid) from public, anon, authenticated;
revoke all on function public.toggle_post_cheers(uuid) from public, anon;
revoke all on function public.add_comment(uuid, text, uuid[]) from public, anon;
revoke all on function public.delete_comment(uuid) from public, anon;
revoke all on function public.post_comments_page(uuid, timestamptz, uuid, int) from public, anon;

grant execute on function public.toggle_post_cheers(uuid) to authenticated;
grant execute on function public.add_comment(uuid, text, uuid[]) to authenticated;
grant execute on function public.delete_comment(uuid) to authenticated;
grant execute on function public.post_comments_page(uuid, timestamptz, uuid, int) to authenticated;
