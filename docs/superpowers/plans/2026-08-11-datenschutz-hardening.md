# Datenschutz Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Tasks:** 6. Every SQL task ends with `./supabase/tests/run_local_pg.sh` green.

**Goal:** Bring the CheekyPint backend in line with DSGVO/Austrian DSG obligations that are engineering work rather than paperwork: make post photos genuinely access-controlled, make the published retention policy actually happen, and give users a way to obtain their data.

**Architecture:** Four backend changes plus one document. Post photos move from a public bucket to a private one governed by a friend-aware policy on `storage.objects`, so Postgres authorises every fetch. Because purging a `posts` row destroys the only record of its `image_path`, a `storage_gc_queue` table records objects to delete *before* rows go away; an Edge Function drains it. Retention purges then become safe, and a caller-scoped export RPC satisfies Art. 15/20.

**Tech Stack:** PostgreSQL 16, Supabase (Storage RLS, RPCs, Edge Functions/Deno), `psql` test harness.

## Global Constraints

- **Migrations are append-only** (`CONTRIBUTING.md:25`). Every change is a NEW file. The feed migrations `20260811000100`–`000800` are settled — never edit them.
- New tables: `enable row level security`, `revoke all ... from public, anon, authenticated`, **no policies** unless the table is deliberately client-readable. Access via `security definer` RPCs.
- Functions: `security definer`, `set search_path = ''`, all identifiers schema-qualified, `revoke all ... from public, anon;` then `grant execute ... to authenticated;` — except maintenance functions, which are revoked from `authenticated` too and run only via the service role or a scheduled job.
- Every mutating RPC calls `public.enforce_rate_limit`.
- **Negative tests must use the `ok` pattern** — raise the FAIL *outside* the `exception when others` handler, or the test can never fail. Compare with `is distinct from`, never `<>`.
- New test blocks go **before** the trailing `reset role; \echo 'ALL RLS/RPC CHECKS PASSED'` banner. The suite currently ends at **t48**; Task 3 starts at **t49**.
- Seeded identities: Alice `…a1`, Barnaby `…b2`, Ceri `…c3`, Dev `…d4`. **The seed graph is NOT the graph your test sees.** The suite mutates state as it runs: by t44 Ceri and Barnaby are accepted friends and Dev is friended with Barnaby too, so a block that assumes "Ceri is not Barnaby's friend" (true at seed time) is silently testing a *friend*. Before relying on any relationship, either assert it or establish it in your own setup (`remove_friend` / `send_friend_request` + accept). Filter every `feed_page` select by `author_id` — earlier tests seeded posts for several authors.
- `public.posts` is RLS-enabled with no policies, so a direct `select … from public.posts` returns nothing even for its author. Read post ids through `feed_page`, never a raw table select.
- Mind per-identity rate limits when seeding: `post_create` 20/hr, `post_comment` 60/hr, `cheers_toggle` 120/hr, `report` 20/hr.
- `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` for any Swift/Xcode command.
- No Swift changes in Tasks 1–4. The client work (ImageLoader sending a bearer token, an export screen) belongs to the Part B2 plan.
- Work on branch `feat/datenschutz-hardening`, cut from `feat/feed-backend`. Commit per task. Never touch `master`.

---

## File Structure

| File | Responsibility |
|---|---|
| `supabase/migrations/20260812000100_private_post_images.sql` | Flip `post-images` to private; friend-aware SELECT policy on `storage.objects` |
| `supabase/migrations/20260812000200_storage_gc_queue.sql` | `storage_gc_queue` table + `enqueue_storage_object()` helper |
| `supabase/migrations/20260812000300_enqueue_deleted_post_images.sql` | `delete_post` also enqueues its photo for deletion |
| `supabase/migrations/20260812000400_retention_purges.sql` | `purge_soft_deleted_*` maintenance functions |
| `supabase/migrations/20260812000500_export_my_data.sql` | `export_my_data()` — Art. 15/20 |
| `supabase/functions/storage-gc/index.ts` | Drains `storage_gc_queue` with the service role |
| `supabase/tests/rls_rpc_suite.sql` | Extended, t46 onward |
| `docs/DPIA.md` | Data-protection impact assessment (Art. 35) |
| `docs/RECORDS_OF_PROCESSING.md` | Art. 30 record |

---

### Task 1: Private `post-images` bucket with a friend-aware read policy

**Files:**
- Create: `supabase/migrations/20260812000100_private_post_images.sql`
- Modify: `supabase/tests/rls_rpc_suite.sql` (append t46)

**Interfaces:**
- Consumes: `public.posts`, `public.is_accepted_friend(uuid, uuid)`.
- Produces: bucket `post-images` with `public = false`; `public.can_read_post_image(uuid, text) returns boolean` (granted to `authenticated` — a policy body runs as the querying role); policy `post_images_read_visible_posts` on `storage.objects`.

- [ ] **Step 1: Write the failing test**

Append before the banner:

```sql
-- ============================ STORAGE: private post photos ============================
-- The suite's shim gives storage.objects RLS but no policies, so these assertions exercise the
-- policy we are about to add. Rows are inserted with the service role (reset role) because the
-- shim grants no INSERT policy on storage.objects.
reset role;
insert into storage.objects (bucket_id, name)
values ('post-images', '00000000-0000-4000-8000-0000000000b2/barnaby-pint.jpg')
on conflict do nothing;

-- Give Barnaby a post that references it so the policy has something to join to.
set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000b2';
do $$ begin
  perform public.create_post('storage policy fixture', '00000000-0000-4000-8000-0000000000b2/barnaby-pint.jpg', null, null);
end $$;

do $$ declare v_bucket_public boolean; visible int; begin
  select public.bucket_is_public('post-images') into v_bucket_public;
  if v_bucket_public is distinct from false then
    raise exception 'FAIL t46: post-images bucket is still public'; end if;

  -- Author sees their own object.
  select count(*) into visible from storage.objects
   where bucket_id = 'post-images' and name like '00000000-0000-4000-8000-0000000000b2/%';
  if visible is distinct from 1 then
    raise exception 'FAIL t46: author sees % of own objects (want 1)', visible; end if;
  raise notice 'PASS t46: the bucket is private and the author can read their own photo';
end $$;

-- Alice is Barnaby's accepted friend -> may read.
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000a1';
do $$ declare visible int; begin
  select count(*) into visible from storage.objects
   where bucket_id = 'post-images' and name like '00000000-0000-4000-8000-0000000000b2/%';
  if visible is distinct from 1 then
    raise exception 'FAIL t46: friend sees % (want 1)', visible; end if;
  raise notice 'PASS t46: an accepted friend can read the photo';
end $$;

-- Ceri is Alice's friend but NOT Barnaby's -> must not read.
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000c3';
do $$ declare visible int; begin
  select count(*) into visible from storage.objects
   where bucket_id = 'post-images' and name like '00000000-0000-4000-8000-0000000000b2/%';
  if visible is distinct from 0 then
    raise exception 'FAIL t46: non-friend sees % objects (want 0)', visible; end if;
  raise notice 'PASS t46: a non-friend cannot read the photo';
end $$;
```

- [ ] **Step 2: Run the suite to verify it fails**

```bash
cd ~/Projects/cheekypint && ./supabase/tests/run_local_pg.sh
```

Expected: FAIL — `function public.bucket_is_public(text) does not exist`.

- [ ] **Step 3: Create the migration**

```sql
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

-- Answers the storage policy's question without tripping over posts' own RLS. A policy body is
-- evaluated with the CALLER's privileges, and public.posts is RLS-enabled with no policies, so a
-- plain `exists (select ... from public.posts ...)` inside the policy always returns false —
-- including for the object's own author, making every photo unreadable. A security-definer helper
-- runs as the owner and can read posts, while still deciding from the uid it is handed.
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

-- Unlike can_view_post (revoked from authenticated because it is only called from inside other
-- security-definer functions), this MUST be executable by `authenticated`: an RLS policy body runs
-- as the querying role. That is not a new leak — it answers exactly what the policy already reveals
-- by returning the row or not. Do not "tighten" this grant; doing so silently breaks every photo.
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
```

Note: the policy joins on `p.image_path = storage.objects.name`, which holds because `create_post`
requires the first path segment to be the uploader's uid and stores the path verbatim
(`20260811000500_rpc_feed_posts.sql:46-55`).

- [ ] **Step 4: Run the suite to verify it passes**

Expected: three `PASS t46` notices and every earlier block still green.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260812000100_private_post_images.sql supabase/tests/rls_rpc_suite.sql
git commit -m "feat: make post photos private and friend-gated in storage"
```

---

### Task 2: `storage_gc_queue`

**Files:**
- Create: `supabase/migrations/20260812000200_storage_gc_queue.sql`
- Create: `supabase/functions/storage-gc/index.ts`
- Modify: `supabase/tests/rls_rpc_suite.sql` (append t47)

**Interfaces:**
- Produces: table `public.storage_gc_queue (id, bucket_id, object_path, enqueued_at, processed_at, attempts, last_error)`; `public.enqueue_storage_object(p_bucket text, p_path text) returns void`; `public.claim_storage_gc(p_limit int) returns table (id uuid, bucket_id text, object_path text)`; `public.mark_storage_gc_done(p_ids uuid[]) returns void`.

- [ ] **Step 1: Write the failing test**

```sql
-- ============================ STORAGE GC QUEUE ============================
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000a1';
do $$ declare visible int; begin
  select count(*) into visible from public.storage_gc_queue;
  if visible is distinct from 0 then
    raise exception 'FAIL t47: storage_gc_queue exposed % rows to a client', visible; end if;
  raise notice 'PASS t47: the GC queue is invisible to clients';
end $$;

do $$ declare ok boolean := false; begin
  begin
    perform public.enqueue_storage_object('post-images', 'x/y.jpg');
  exception when others then ok := true;
  end;
  if not ok then raise exception 'FAIL t47: a client could enqueue a GC entry'; end if;
  raise notice 'PASS t47: clients cannot enqueue GC work directly';
end $$;
```

- [ ] **Step 2: Run the suite to verify it fails**

Expected: FAIL — `relation "public.storage_gc_queue" does not exist`.

- [ ] **Step 3: Create the migration**

```sql
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
```

- [ ] **Step 4: Run the suite to verify it passes**

Expected: two `PASS t47` notices.

- [ ] **Step 5: Write the drain Edge Function**

Create `supabase/functions/storage-gc/index.ts`. Read `supabase/functions/delete-account/index.ts` first and follow its structure, imports, CORS handling and `json()` helper exactly. Behaviour:

- Require the service role: reject unless the caller presents the service-role key (this function is for scheduled invocation, not clients). Mirror how `delete-account` builds its `admin` client.
- Call `claim_storage_gc(200)` via `rpc`.
- Group the returned rows by `bucket_id` and call `admin.storage.from(bucket).remove(paths)` per bucket.
- On success call `mark_storage_gc_done` with the ids that were removed. On failure, leave them unprocessed and return a 500 with the error — do **not** mark them done, and do not loop retrying.
- Return `{ processed: <count> }`.

State in your report that you could not execute it (no Deno toolchain) and hand-trace: empty queue, one object, two buckets in one batch, and `remove()` failing.

- [ ] **Step 6: Commit**

```bash
git add supabase/migrations/20260812000200_storage_gc_queue.sql supabase/functions/storage-gc supabase/tests/rls_rpc_suite.sql
git commit -m "feat: add a storage GC queue so purges cannot orphan objects"
```

---

### Task 3: Enqueue photos when a post is deleted, and add retention purges

**Files:**
- Create: `supabase/migrations/20260812000300_enqueue_deleted_post_images.sql`
- Create: `supabase/migrations/20260812000400_retention_purges.sql`
- Modify: `supabase/tests/rls_rpc_suite.sql` (append t49–t50)

**Interfaces:**
- Consumes: `public.enqueue_storage_object(text, text)` from Task 2.
- Produces: `delete_post` also enqueues its photo; `public.purge_soft_deleted_posts(p_older_than interval)`, `public.purge_soft_deleted_comments(p_older_than interval)`, `public.purge_soft_deleted_pint_entries(p_older_than interval)`, `public.purge_resolved_reports(p_older_than interval)` — each returns `int` (rows purged).

- [ ] **Step 1: Write the failing tests**

```sql
-- ============================ RETENTION ============================
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000a1';
do $$ declare v jsonb; v_post uuid; queued int; begin
  select public.create_post('retention fixture', '00000000-0000-4000-8000-0000000000a1/retain.jpg', null, null) into v;
  v_post := (v->>'post_id')::uuid;
  perform public.delete_post(v_post);
  reset role;
  select count(*) into queued from public.storage_gc_queue
   where bucket_id = 'post-images' and object_path = '00000000-0000-4000-8000-0000000000a1/retain.jpg';
  if queued is distinct from 1 then
    raise exception 'FAIL t49: deleting a post queued % GC entries (want 1)', queued; end if;
  raise notice 'PASS t49: deleting a post queues its photo for storage deletion';
end $$;

reset role;
do $$ declare purged int; still int; begin
  -- Age the soft-deleted rows past the retention window, then purge.
  update public.posts set deleted_at = now() - interval '40 days' where deleted_at is not null;
  select public.purge_soft_deleted_posts(interval '30 days') into purged;
  if purged < 1 then raise exception 'FAIL t50: purge removed % posts (want >=1)', purged; end if;
  select count(*) into still from public.posts where deleted_at < now() - interval '30 days';
  if still is distinct from 0 then
    raise exception 'FAIL t50: % aged soft-deleted posts survived the purge', still; end if;
  raise notice 'PASS t50: aged soft-deleted posts are purged';
end $$;

reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000a1';
do $$ declare ok boolean := false; begin
  begin
    perform public.purge_soft_deleted_posts(interval '30 days');
  exception when others then ok := true;
  end;
  if not ok then raise exception 'FAIL t50: a client could run a retention purge'; end if;
  raise notice 'PASS t50: retention purges are not client-callable';
end $$;
```

- [ ] **Step 2: Run the suite to verify it fails**

Expected: FAIL — `FAIL t48` (nothing queued) or a missing-function error.

- [ ] **Step 3: Make `delete_post` enqueue its photo**

Create `20260812000300_enqueue_deleted_post_images.sql`. `create or replace` the whole `delete_post` function — copy its current body from `20260811000500_rpc_feed_posts.sql` verbatim and add the enqueue. Do **not** edit the original migration. The function must:

- keep its existing auth guard, `enforce_rate_limit('post_delete', 60, interval '1 hour')`, and the `author_id = v_uid and deleted_at is null` predicate with the `P0002` on no-match
- capture the row's `image_path` in the `update ... returning` and, when non-null, call `public.enqueue_storage_object('post-images', <path>)`

Add a comment explaining that soft-deleting hid the row while leaving the object fetchable, so deletion now also schedules the bytes for removal.

- [ ] **Step 4: Write the purge functions**

Create `20260812000400_retention_purges.sql`. For each of the four, follow this shape (shown for posts; repeat the full body for each rather than abbreviating):

```sql
-- Retention purges. docs/legal/DATA_RETENTION_POLICY.md promises soft-deleted content is purged
-- within 30 days and resolved reports kept 12-24 months; nothing enforced that until now — the
-- only scheduled job in the schema was prune_rate_limit_events. These are maintenance functions:
-- revoked from `authenticated` and intended for a scheduled service-role invocation.
--
-- Order matters: enqueue the storage object BEFORE deleting the row, because the row holds the
-- only copy of image_path.

create or replace function public.purge_soft_deleted_posts(p_older_than interval default interval '30 days')
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count int;
begin
  perform public.enqueue_storage_object('post-images', p.image_path)
     from public.posts p
    where p.deleted_at is not null
      and p.deleted_at < now() - p_older_than
      and p.image_path is not null;

  with gone as (
    delete from public.posts
     where deleted_at is not null
       and deleted_at < now() - p_older_than
    returning 1
  )
  select count(*)::int into v_count from gone;

  return v_count;
end;
$$;
```

`purge_soft_deleted_comments` and `purge_soft_deleted_pint_entries` are the same without the enqueue step (neither references storage). Check the actual soft-delete column name on `pint_entries` before writing it — read `20260101000200_core_tables.sql` rather than assuming `deleted_at`. `purge_resolved_reports` deletes where `status in ('actioned','dismissed')` and `reviewed_at < now() - p_older_than`, defaulting to `interval '18 months'` (mid-point of the published 12–24).

Revoke all four from `public, anon, authenticated` and grant to nobody — service role only, matching `prune_rate_limit_events` (`20260101000600_security_helpers.sql:140`).

- [ ] **Step 5: Run the suite to verify it passes**

Expected: `PASS t49` and both `PASS t50` notices.

- [ ] **Step 6: Document the schedule**

Add a short section to `docs/RELEASE_CHECKLIST.md` under Backend listing the jobs to schedule and their cadence: `prune_rate_limit_events` daily, `purge_soft_deleted_posts` / `_comments` / `_pint_entries` daily, `purge_resolved_reports` weekly, and the `storage-gc` Edge Function hourly. State that without these scheduled, `docs/legal/DATA_RETENTION_POLICY.md` is not satisfied.

- [ ] **Step 7: Commit**

```bash
git add supabase/migrations/20260812000300_enqueue_deleted_post_images.sql \
        supabase/migrations/20260812000400_retention_purges.sql \
        supabase/tests/rls_rpc_suite.sql docs/RELEASE_CHECKLIST.md
git commit -m "feat: enforce the published retention policy"
```

---

### Task 4: `export_my_data()` — Art. 15 access and Art. 20 portability

**Files:**
- Create: `supabase/migrations/20260812000500_export_my_data.sql`
- Modify: `supabase/tests/rls_rpc_suite.sql` (append t52)

**Interfaces:**
- Produces: `public.export_my_data() returns jsonb` — one document containing the caller's profile, privacy settings, pint entries, posts, comments, cheers given, friends and blocks.

- [ ] **Step 1: Write the failing test**

```sql
-- ============================ DATA EXPORT (Art. 15 / 20) ============================
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000a1';
do $$ declare v jsonb; begin
  select public.export_my_data() into v;
  if v is null then raise exception 'FAIL t51: export returned null'; end if;
  if (v->'profile'->>'id') is distinct from '00000000-0000-4000-8000-0000000000a1' then
    raise exception 'FAIL t51: export profile id is %', v->'profile'->>'id'; end if;
  if jsonb_typeof(v->'pint_entries') is distinct from 'array' then
    raise exception 'FAIL t51: pint_entries is not an array'; end if;
  if jsonb_array_length(v->'pint_entries') < 1 then
    raise exception 'FAIL t51: export contains no pint entries for a user who has 4'; end if;
  -- The export must be caller-scoped: no other user's rows may appear.
  if exists (
    select 1 from jsonb_array_elements(v->'pint_entries') e
     where (e->>'user_id') is distinct from '00000000-0000-4000-8000-0000000000a1'
  ) then raise exception 'FAIL t51: export leaked another user''s pint entries'; end if;
  raise notice 'PASS t51: export_my_data returns the caller''s own data only';
end $$;
```

- [ ] **Step 2: Run the suite to verify it fails**

Expected: FAIL — `function public.export_my_data() does not exist`.

- [ ] **Step 3: Write the function**

Create `20260812000500_export_my_data.sql`. `security definer`, `set search_path = ''`, auth guard raising `28000`, `perform public.enforce_rate_limit('data_export', 5, interval '24 hours')`.

Build one `jsonb_build_object` with keys `exported_at`, `profile`, `privacy_settings`, `pint_entries`, `posts`, `comments`, `cheers_given`, `friends`, `blocks`. Every subquery must filter to `auth.uid()` — for `friends`, include the friendship rows the caller is party to; for `posts` and `comments`, the caller's own authored rows including soft-deleted ones (they are still the caller's data until purged).

Use `coalesce(jsonb_agg(...), '[]'::jsonb)` for every collection so an empty set exports as `[]` rather than `null`. Do **not** include other users' display names or avatars beyond what is inherently part of a friendship row — an export is the caller's data, not their friends'.

Read the actual column lists from `20260101000200_core_tables.sql`, `20260101000300_social_tables.sql` and `20260811000100_feed_tables.sql` rather than guessing; do not use `to_jsonb(t.*)` on tables containing another user's identifiers without thinking about what it exposes.

Then `revoke all ... from public, anon;` and `grant execute ... to authenticated;`.

- [ ] **Step 4: Run the suite to verify it passes**

Expected: `PASS t51`.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260812000500_export_my_data.sql supabase/tests/rls_rpc_suite.sql
git commit -m "feat: add a caller-scoped data export RPC"
```

---

### Task 5: DPIA and Art. 30 records

**Files:**
- Create: `docs/DPIA.md`
- Create: `docs/RECORDS_OF_PROCESSING.md`
- Modify: `docs/RELEASE_CHECKLIST.md`

No code and no tests. Both documents must describe **what the code actually does** — read the shipped SQL and cite `file:line`, exactly as `docs/MODERATION.md` does. Where a fact depends on the operator's choices you do not have (legal entity, address, DPO contact, Supabase region, retention job schedule), write a clearly marked `[[placeholder]]` rather than inventing it — that is the existing convention in `docs/legal/`.

- [ ] **Step 1: Write `docs/RECORDS_OF_PROCESSING.md`** (Art. 30)

Cover: controller identity `[[placeholder]]`; processing purposes; categories of data subjects (adult users who confirmed legal drinking age) and of personal data — enumerate them from the schema, including profile fields, drink entries with timestamps and volumes, pub/location tags, post bodies, post photos, comments, mentions, friend graph, blocks, reports, rate-limit events; recipients (Supabase as processor, `[[region]]`, `[[DPA reference]]`); third-country transfers; retention per category, cross-referencing `docs/legal/DATA_RETENTION_POLICY.md` and naming the purge function that enforces each; and security measures — RLS-with-no-policies, `security definer` RPCs, the friend-aware storage policy, sanitisation, rate limits.

- [ ] **Step 2: Write `docs/DPIA.md`** (Art. 35)

Structure it as: description of processing; necessity and proportionality; **risks to data subjects**; measures; residual risk; and a decision/sign-off section left for the operator.

The risk section must be honest and specific. Include at minimum:

1. **Alcohol-consumption data may be special-category (Art. 9) health data.** The app records how much a named person drinks, with timestamps, over time. State plainly that this classification is **unresolved and requires qualified legal advice**, that it would change the lawful basis, and do not assert a conclusion either way.
2. **Photographs may contain third parties** who are not users and have given no consent — a pub photo can include bystanders. Note the mitigations (friends-only, private bucket, reporting) and that no consent mechanism exists for depicted non-users.
3. **Location inference.** `place_label` and `pub_id` reveal where a user was and when; combined with drink entries this builds a movement-and-consumption profile.
4. **Re-identification via the friend graph**, even with quantities hidden.
5. **Residual retention risk:** a photo URL fetched while access was permitted cannot be recalled; deletion revokes future access, not copies already made.
6. **Moderation is reactive** (report-driven), with no proactive image scanning — appropriate for a friends-only surface, and state that explicitly as the justification.

- [ ] **Step 3: Link them**

Add both to `docs/RELEASE_CHECKLIST.md` under Legal, alongside the existing counsel-review item, and note that the Art. 9 question must be resolved before launch.

- [ ] **Step 4: Commit**

```bash
git add docs/DPIA.md docs/RECORDS_OF_PROCESSING.md docs/RELEASE_CHECKLIST.md
git commit -m "docs: add DPIA and Article 30 records of processing"
```

---

### Task 6: Close the friend-graph oracle

Found during Task 1's review. `supabase/migrations/20260101000900_grants.sql` runs
`grant execute on all functions in schema public to authenticated` **after**
`20260101000600_security_helpers.sql` created its helpers, and unlike `can_view_post` they were
never individually revoked. So any authenticated user can call
`select public.is_accepted_friend('<any-uid>', '<any-other-uid>')` directly and learn whether two
arbitrary people are friends — a direct read of other people's social graph, with no post, photo or
comment involved. `is_blocked` is worse: it discloses that a specific pair has blocked each other.

This is a DSGVO-relevant confidentiality defect, pre-existing and unrelated to the feed.

**Verified before writing this task:** no RLS policy calls these helpers directly — the only
policy-side use is inside `public.can_read_post_image`, which is `security definer` and therefore
runs as the owner. So revoking client EXECUTE breaks nothing.

**Files:**
- Create: `supabase/migrations/20260812000600_revoke_helper_oracles.sql`
- Modify: `supabase/tests/rls_rpc_suite.sql` (append t52)

**Interfaces:** no new objects. Removes `authenticated` EXECUTE from four helpers.

- [ ] **Step 1: Write the failing test**

```sql
-- ============================ HELPER ORACLES ============================
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000c3';
do $$
declare ok_friend boolean := false; ok_blocked boolean := false; ok_profile boolean := false;
begin
  -- Ceri must not be able to interrogate other people's relationships directly.
  begin
    perform public.is_accepted_friend(
      '00000000-0000-4000-8000-0000000000a1', '00000000-0000-4000-8000-0000000000b2');
  exception when others then ok_friend := true;
  end;
  begin
    perform public.is_blocked(
      '00000000-0000-4000-8000-0000000000a1', '00000000-0000-4000-8000-0000000000d4');
  exception when others then ok_blocked := true;
  end;
  begin
    perform public.can_view_profile(
      '00000000-0000-4000-8000-0000000000a1', '00000000-0000-4000-8000-0000000000b2');
  exception when others then ok_profile := true;
  end;
  if not ok_friend then raise exception 'FAIL t52: is_accepted_friend is a client-callable oracle'; end if;
  if not ok_blocked then raise exception 'FAIL t52: is_blocked is a client-callable oracle'; end if;
  if not ok_profile then raise exception 'FAIL t52: can_view_profile is a client-callable oracle'; end if;
  raise notice 'PASS t52: relationship helpers are not callable by clients';
end $$;

-- ...and the feed still works, i.e. the revoke did not break the definer functions that use them.
do $$ declare visible int; begin
  select count(*) into visible from public.feed_page(null, null, 20);
  if visible < 1 then raise exception 'FAIL t52: feed_page returned % rows after the revoke', visible; end if;
  raise notice 'PASS t52: feed_page still works — nested definer calls are unaffected';
end $$;
```

- [ ] **Step 2: Run the suite to verify it fails**

```bash
cd ~/Projects/cheekypint && ./supabase/tests/run_local_pg.sh
```

Expected: FAIL at `FAIL t52: is_accepted_friend is a client-callable oracle` — the blanket grant is
still in force.

- [ ] **Step 3: Create the migration**

```sql
-- CheekyPint: relationship helpers must not be client-callable.
--
-- 20260101000900_grants.sql runs `grant execute on all functions in schema public to
-- authenticated` after 20260101000600_security_helpers.sql created these, and unlike can_view_post
-- they were never individually revoked. That left any authenticated user able to ask
-- `is_accepted_friend(<a>, <b>)` about arbitrary people — a direct read of someone else's social
-- graph — and `is_blocked(<a>, <b>)`, which discloses that a specific pair blocked each other.
--
-- Safe to revoke: no RLS policy calls these. The only policy-side use is inside
-- public.can_read_post_image, which is security definer and runs as the owner, as do every RPC and
-- helper that composes them.
revoke execute on function public.is_accepted_friend(uuid, uuid) from authenticated;
revoke execute on function public.is_blocked(uuid, uuid) from authenticated;
revoke execute on function public.can_view_profile(uuid, uuid) from authenticated;
revoke execute on function public.shares_active_session(uuid, uuid) from authenticated;
```

Read `20260101000600_security_helpers.sql` first and confirm those four signatures character for
character; if any differs, use the real one and say so in your report. If any **other** function in
that file is also client-granted and only ever used internally, add it and justify it.

- [ ] **Step 4: Run the suite to verify it passes**

Expected: both `PASS t52` notices, and every earlier block still green — that second assertion is
the important one, since it proves the revoke did not break the definer functions built on these.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260812000600_revoke_helper_oracles.sql supabase/tests/rls_rpc_suite.sql
git commit -m "fix: stop clients interrogating other users' relationships directly"
```

---

## Not in this plan

**Part B2 (the client).** The Feed tab, compose sheet, place picker, comments UI, report UI, an export screen, and — required by Task 1 — teaching `ImageLoader` to send the caller's bearer token, since post photos are no longer publicly readable. Write that plan after this one is green.

Also out of scope: resolving the Art. 9 classification (legal advice); filling operator placeholders; scheduling the jobs on the hosted project; counsel review of `docs/legal/*`.
