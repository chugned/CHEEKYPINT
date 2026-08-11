-- CheekyPint: delete_post also schedules its photo for storage deletion.
--
-- Soft-deleting a post only ever hid the row from the read paths (feed_page,
-- post_comments_page, the storage.objects RLS policy's `p.deleted_at is null` join). The
-- underlying object in the post-images bucket was left fetchable-once-known and, once the row
-- itself was later purged by retention, unreachable forever — the row was the only place
-- image_path lived. That is exactly how account deletion orphaned photos permanently in the
-- (then-public) bucket. So delete_post now captures the row's image_path in the same
-- update...returning that soft-deletes it, and — before returning to the caller — enqueues that
-- path for the storage-gc Edge Function to actually remove the bytes.
--
-- create or replace from a NEW migration file, per the append-only rule: the body below is
-- copied verbatim from 20260811000500_rpc_feed_posts.sql (never edited) with the capture +
-- enqueue added. The signature is unchanged (still `delete_post(uuid) returns void`), so this
-- replaces the existing function in place rather than creating an overload, and the grants from
-- 20260811000500 (revoke all from public/anon; grant execute to authenticated) carry over
-- untouched — CREATE OR REPLACE FUNCTION preserves a function's ACL because its oid is unchanged.

create or replace function public.delete_post(p_post_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_image text;
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;

  perform public.enforce_rate_limit('post_delete', 60, interval '1 hour');

  update public.posts
     set deleted_at = now()
   where id = p_post_id
     and author_id = v_uid
     and deleted_at is null
  returning image_path into v_image;

  if not found then
    raise exception 'Post not available' using errcode = 'P0002';
  end if;

  -- Order matters: enqueue BEFORE the function returns, using the image_path captured in the
  -- same statement that soft-deleted the row — once we return, nothing else holds that path.
  if v_image is not null then
    perform public.enqueue_storage_object('post-images', v_image);
  end if;
end;
$$;
