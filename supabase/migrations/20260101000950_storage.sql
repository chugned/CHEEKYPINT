-- CheekyPint schema — 09b. Storage: avatars bucket
--
-- Profile images live in the `avatars` bucket. Files are keyed by the owner's uid folder:
--   avatars/<user_id>/<random>.jpg
-- Writes are restricted to a user's own folder. Reads are allowed for authenticated users;
-- because avatar visibility is enforced when RPCs choose whether to RETURN an avatar_path,
-- and file names carry an unguessable random component, images are effectively unlisted.
--
-- NOTE: This is a documented tradeoff (see docs/PRIVACY.md). A hardening pass can switch to
-- a fully private bucket served via short-lived signed URLs minted after RPC authorisation.

insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do nothing;

-- Owner-only writes into their own <user_id>/ prefix.
create policy "avatars_insert_own_folder"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "avatars_update_own_folder"
  on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "avatars_delete_own_folder"
  on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

create policy "avatars_read_authenticated"
  on storage.objects for select to authenticated
  using (bucket_id = 'avatars');
