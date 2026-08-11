-- CheekyPint: feed post RPCs. Visibility is "self or accepted friend", which
-- public.is_accepted_friend already narrows to non-blocked pairs in both directions.

create or replace function public.create_post(
  p_body text default null,
  p_image_path text default null,
  p_place_label text default null,
  p_pub_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_body text;
  v_label text;
  v_image text;
  v_row public.posts;
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;

  perform public.enforce_rate_limit('post_create', 20, interval '1 hour');

  v_body := nullif(btrim(public.strip_ugc_control_chars(p_body)), '');
  v_label := nullif(btrim(public.strip_ugc_control_chars(p_place_label)), '');
  -- Sanitised once into a local so the emptiness check and the insert always agree — an
  -- unsanitised image_path let whitespace-only paths (e.g. a bare tab) through the guard.
  v_image := nullif(btrim(public.strip_ugc_control_chars(p_image_path)), '');

  if v_body is null and v_image is null then
    raise exception 'A post needs a photo or some words' using errcode = '22023';
  end if;
  if p_pub_id is not null and v_label is null then
    raise exception 'A pub reference needs a place label' using errcode = '22023';
  end if;
  -- Reject any path-traversal segment first. The ownership check below only inspects the
  -- FIRST folder segment, so 'b2/../a1/x.jpg' would otherwise pass it (Barnaby's own uid
  -- leads the path) while most HTTP clients/CDNs normalise the URL down to 'a1/x.jpg' before
  -- it ever reaches storage — reaching exactly the photo the ownership check exists to block.
  if v_image is not null and position('..' in v_image) > 0 then
    raise exception 'Image path is invalid' using errcode = '22023';
  end if;
  -- The bucket's own insert policy (20260811000200_feed_storage.sql) restricts uploads to the
  -- uploader's own folder; mirror that here so a caller cannot pass someone ELSE's already-
  -- uploaded (unguessable but readable-once-known) path and re-broadcast their photo.
  -- storage.foldername() drops the final (filename) segment, so a path with no '/' at all
  -- (e.g. 'sneaky.jpg') returns an empty array and [1] is NULL. A bare "<> v_uid::text" would
  -- make that comparison NULL, silently skipping the `if` and letting the path through — the
  -- coalesce()+`is distinct from` form below treats a missing folder as "not mine" instead.
  if v_image is not null
     and coalesce((storage.foldername(v_image))[1], '') is distinct from v_uid::text then
    raise exception 'Image must be in your own folder' using errcode = '22023';
  end if;

  insert into public.posts (author_id, body, image_path, place_label, pub_id)
  values (v_uid, left(v_body, 500), v_image, left(v_label, 80), p_pub_id)
  returning * into v_row;

  return jsonb_build_object('post_id', v_row.id);
end;
$$;

create or replace function public.delete_post(p_post_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;

  perform public.enforce_rate_limit('post_delete', 60, interval '1 hour');

  update public.posts
     set deleted_at = now()
   where id = p_post_id
     and author_id = v_uid
     and deleted_at is null;

  if not found then
    raise exception 'Post not available' using errcode = 'P0002';
  end if;
end;
$$;

-- NOTE on the missing auth guard below: feed_page is `language sql`, which has no IF/RAISE of
-- its own. A `with _auth_guard as (select public._assert_authenticated()) ... from _auth_guard,
-- public.posts p ...` cross-join was tried and reverted — verified empirically that when the
-- caller is unauthenticated, auth.uid() is null, so the posts/friendship predicates already
-- filter to zero rows on their own; Postgres's planner then treats _auth_guard as the inner
-- side of a nested loop and never evaluates it, since zero rows on the outer side means the
-- join result is empty regardless. The guard function was silently skipped and the query still
-- returned an empty set instead of raising 28000. Making the guard fire reliably needs either a
-- plpgsql wrapper (an extra round trip) or restructuring feed_page as `language plpgsql` with
-- `return query`. Deferred per the accepted tradeoff: an unauthenticated caller gets zero rows
-- instead of a 28000 error, which is a worse error message but not an access-control gap — the
-- REVOKE/GRANT pair below already restricts EXECUTE to the `authenticated` role.

create or replace function public.feed_page(
  p_before timestamptz default null,
  p_before_id uuid default null,
  p_limit int default 20
)
returns table (
  post_id uuid,
  author_id uuid,
  display_name text,
  avatar_path text,
  body text,
  image_path text,
  place_label text,
  pub_id uuid,
  created_at timestamptz,
  cheers_count int,
  viewer_has_cheered boolean,
  comment_count int
)
language sql
stable
security definer
set search_path = ''
as $$
  select p.id,
         p.author_id,
         pr.display_name,
         -- Mirror the established avatar-visibility gate (see get_friend_leaderboard in
         -- 20260101000800_rpc_social.sql): self always sees it; a friend only when the owner
         -- has avatar_visibility = 'friends'.
         case when p.author_id = auth.uid() or ps.avatar_visibility = 'friends'
              then pr.avatar_path end,
         p.body,
         p.image_path,
         p.place_label,
         p.pub_id,
         p.created_at,
         (select count(*)::int from public.post_cheers c where c.post_id = p.id),
         exists (select 1 from public.post_cheers c
                  where c.post_id = p.id and c.user_id = auth.uid()),
         (select count(*)::int from public.post_comments cm
           where cm.post_id = p.id and cm.deleted_at is null)
    from public.posts p
    join public.profiles pr on pr.id = p.author_id
    join public.privacy_settings ps on ps.user_id = p.author_id
   where p.deleted_at is null
     and pr.deleted_at is null
     and (p.author_id = auth.uid() or public.is_accepted_friend(auth.uid(), p.author_id))
     -- Compound keyset cursor: created_at alone ties whenever a batch insert shares one
     -- transaction timestamp, which silently dropped rows under a strict "<" on created_at.
     -- A cursor is both halves or neither; a caller that supplies p_before but omits
     -- p_before_id has an incomplete cursor. feed_page is `language sql`, so it cannot RAISE
     -- to reject that case (see the M5 note above on why a guard can't reliably fire here
     -- either); coalescing the missing half to the MAXIMUM uuid instead of the minimum makes
     -- the failure mode "may repeat a tied row across pages" rather than "silently drops it
     -- forever" — repeats are recoverable client-side (dedupe by id), permanent loss is not.
     and (p_before is null
          or (p.created_at, p.id) < (p_before, coalesce(p_before_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)))
   order by p.created_at desc, p.id desc
   limit least(greatest(coalesce(p_limit, 20), 1), 50);
$$;

revoke all on function public.create_post(text, text, text, uuid) from public, anon;
revoke all on function public.delete_post(uuid) from public, anon;
revoke all on function public.feed_page(timestamptz, uuid, int) from public, anon;

grant execute on function public.create_post(text, text, text, uuid) to authenticated;
grant execute on function public.delete_post(uuid) to authenticated;
grant execute on function public.feed_page(timestamptz, uuid, int) to authenticated;
