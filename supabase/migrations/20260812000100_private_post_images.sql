-- CheekyPint: post photos become genuinely access-controlled.
--
-- Previously `post-images` was public = true, so any object was retrievable at
-- /storage/v1/object/public/... with no Authorization header and no RLS evaluation. Protection was
-- unguessable filenames — obscurity, not access control: a leaked URL survived unfriending,
-- blocking and post deletion. Making the bucket private moves authorisation into Postgres, so the
-- friend graph governs the bytes themselves and revocation is immediate.
--
-- Deliberately NOT signed URLs: those expire, which breaks HTTP caching and costs a round trip per
-- image. Private + a SELECT policy keeps URLs stable while still requiring a valid token, and the
-- policy re-derives visibility per request. Signed URLs would only be needed to share a photo
-- outside an authenticated session, which nothing does.

update storage.buckets set public = false where id = 'post-images';

-- Small helper so the test suite (and any operator check) can assert bucket visibility without
-- needing direct grants on storage.buckets.
create or replace function public.bucket_is_public(p_bucket text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select b.public from storage.buckets b where b.id = p_bucket;
$$;

revoke all on function public.bucket_is_public(text) from public, anon;
grant execute on function public.bucket_is_public(text) to authenticated;

-- Answers the storage policy's question without tripping over posts' own RLS. The policy body is
-- evaluated with the *caller's* privileges, and public.posts is RLS-enabled with no policies, so a
-- plain subquery there always returns false — including for the object's own author. A
-- security-definer helper runs as the owner and can read posts, while still deciding visibility
-- from the caller's uid that it is passed.
create or replace function public.can_read_post_image(p_uid uuid, p_path text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.posts p
     where p.image_path = p_path
       and p.deleted_at is null
       and (p.author_id = p_uid or public.is_accepted_friend(p_uid, p.author_id))
  );
$$;

comment on function public.can_read_post_image(uuid, text) is
  'Whether p_uid may read the storage object at p_path: it must back a live post they authored or an accepted friend authored.';

-- NOTE the deliberate difference from can_view_post (20260811000600_rpc_feed_social.sql), which is
-- revoked from authenticated because it is only ever called from inside other security-definer
-- functions. This one MUST be granted to authenticated, because an RLS policy body is evaluated as
-- the querying role, so that role needs EXECUTE to even invoke it. That grant is not a new leak —
-- the function answers exactly what the policy already reveals by returning the row or not. Do not
-- "tighten" this revoke/grant pair to match can_view_post's — doing so silently breaks every photo.
revoke all on function public.can_read_post_image(uuid, text) from public, anon;
grant execute on function public.can_read_post_image(uuid, text) to authenticated;

-- Replace the blanket authenticated-read policy with one that asks the feed's own question.
drop policy if exists "post_images_read_authenticated" on storage.objects;

create policy "post_images_read_visible_posts"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'post-images'
    and public.can_read_post_image(auth.uid(), storage.objects.name)
  );
