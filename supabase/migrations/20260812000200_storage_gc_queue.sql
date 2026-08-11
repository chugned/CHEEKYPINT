-- CheekyPint: deferred storage deletion.
--
-- Deleting a posts row destroys the only record of its image_path. That is exactly how account
-- deletion came to orphan photos permanently in a public bucket. So anything that removes a row
-- referencing a storage object must first record the object here; an Edge Function with the
-- service role drains the queue, because SQL cannot delete storage objects itself.

create table public.storage_gc_queue (
  id uuid primary key default gen_random_uuid(),
  bucket_id text not null,
  object_path text not null,
  enqueued_at timestamptz not null default now(),
  processed_at timestamptz,
  attempts int not null default 0,
  last_error text,
  constraint storage_gc_unique unique (bucket_id, object_path)
);

comment on table public.storage_gc_queue is
  'Objects to delete from storage after their owning row is gone. Drained by the storage-gc Edge Function.';

create index storage_gc_pending_idx on public.storage_gc_queue (enqueued_at)
  where processed_at is null;

alter table public.storage_gc_queue enable row level security;
revoke all on table public.storage_gc_queue from public, anon, authenticated;

create or replace function public.enqueue_storage_object(p_bucket text, p_path text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_path is null or btrim(p_path) = '' then return; end if;
  insert into public.storage_gc_queue (bucket_id, object_path)
  values (p_bucket, p_path)
  on conflict (bucket_id, object_path) do nothing;
end;
$$;

create or replace function public.claim_storage_gc(p_limit int default 100)
returns table (id uuid, bucket_id text, object_path text)
language sql
security definer
set search_path = ''
as $$
  select q.id, q.bucket_id, q.object_path
    from public.storage_gc_queue q
   where q.processed_at is null
   order by q.enqueued_at
   limit least(greatest(coalesce(p_limit, 100), 1), 500);
$$;

create or replace function public.mark_storage_gc_done(p_ids uuid[])
returns void
language sql
security definer
set search_path = ''
as $$
  update public.storage_gc_queue
     set processed_at = now()
   where id = any(coalesce(p_ids, array[]::uuid[]));
$$;

-- Maintenance surface: service role only. `enqueue_storage_object` is called from inside other
-- security-definer functions, which run as the owner, so it needs no client grant either.
revoke all on function public.enqueue_storage_object(text, text) from public, anon, authenticated;
revoke all on function public.claim_storage_gc(int) from public, anon, authenticated;
revoke all on function public.mark_storage_gc_done(uuid[]) from public, anon, authenticated;
