-- Claim is now a write, not a read: `for update skip locked` stops two overlapping drains from
-- picking the same rows, and stamping attempts gives a stuck row a visible, rising count instead
-- of failing silently forever.
create or replace function public.claim_storage_gc(p_limit int default 100)
returns table (id uuid, bucket_id text, object_path text)
language sql
security definer
set search_path = ''
as $$
  with picked as (
    select q.id
      from public.storage_gc_queue q
     where q.processed_at is null
     order by q.enqueued_at
     limit least(greatest(coalesce(p_limit, 100), 1), 500)
     for update skip locked
  )
  update public.storage_gc_queue q
     set attempts = q.attempts + 1
    from picked
   where q.id = picked.id
  returning q.id, q.bucket_id, q.object_path;
$$;

create or replace function public.mark_storage_gc_failed(p_ids uuid[], p_error text)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.storage_gc_queue
     set last_error = left(coalesce(p_error, ''), 500)
   where id = any(coalesce(p_ids, array[]::uuid[]))
     and processed_at is null;
$$;

revoke all on function public.mark_storage_gc_failed(uuid[], text) from public, anon, authenticated;
