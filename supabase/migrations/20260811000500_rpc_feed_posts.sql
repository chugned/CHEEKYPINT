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
  v_row public.posts;
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;

  perform public.enforce_rate_limit('post_create', 20, interval '1 hour');

  v_body := nullif(btrim(public.strip_ugc_control_chars(p_body)), '');
  v_label := nullif(btrim(public.strip_ugc_control_chars(p_place_label)), '');

  if v_body is null and nullif(btrim(coalesce(p_image_path, '')), '') is null then
    raise exception 'A post needs a photo or some words' using errcode = '22023';
  end if;
  if p_pub_id is not null and v_label is null then
    raise exception 'A pub reference needs a place label' using errcode = '22023';
  end if;

  insert into public.posts (author_id, body, image_path, place_label, pub_id)
  values (v_uid, left(v_body, 500), nullif(btrim(coalesce(p_image_path, '')), ''),
          left(v_label, 80), p_pub_id)
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

create or replace function public.feed_page(
  p_before timestamptz default null,
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
         pr.avatar_path,
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
   where p.deleted_at is null
     and pr.deleted_at is null
     and (p.author_id = auth.uid() or public.is_accepted_friend(auth.uid(), p.author_id))
     and p.created_at < coalesce(p_before, now() + interval '1 second')
   order by p.created_at desc
   limit least(greatest(coalesce(p_limit, 20), 1), 50);
$$;

revoke all on function public.create_post(text, text, text, uuid) from public, anon;
revoke all on function public.delete_post(uuid) from public, anon;
revoke all on function public.feed_page(timestamptz, int) from public, anon;

grant execute on function public.create_post(text, text, text, uuid) to authenticated;
grant execute on function public.delete_post(uuid) to authenticated;
grant execute on function public.feed_page(timestamptz, int) to authenticated;
