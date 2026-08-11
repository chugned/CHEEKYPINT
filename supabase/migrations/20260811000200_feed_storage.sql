-- CheekyPint: storage for feed post photos.
--
-- Files are keyed by the uploader's uid folder:  post-images/<user_id>/<random>.jpg
-- Writes are restricted to a user's own folder. Reads are allowed for authenticated users;
-- feed visibility is enforced when feed_page decides whether to RETURN an image_path, and file
-- names carry an unguessable random component, so images are effectively unlisted.
--
-- NOTE: same documented tradeoff as the avatars bucket (see docs/PRIVACY.md). A hardening pass
-- can switch to a private bucket served via short-lived signed URLs minted after RPC
-- authorisation.

insert into storage.buckets (id, name, public)
values ('post-images', 'post-images', true)
on conflict (id) do nothing;

create policy "post_images_insert_own_folder"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'post-images'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "post_images_update_own_folder"
  on storage.objects for update to authenticated
  using (bucket_id = 'post-images' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'post-images' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "post_images_delete_own_folder"
  on storage.objects for delete to authenticated
  using (bucket_id = 'post-images' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "post_images_read_authenticated"
  on storage.objects for select to authenticated
  using (bucket_id = 'post-images');
