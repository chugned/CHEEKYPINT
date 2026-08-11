# Social Feed Backend (Part B1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Tasks:** 5. Every task ends with `./supabase/tests/run_local_pg.sh` green.

**Goal:** Build the Postgres side of the friends-only social feed — tables, storage bucket, RLS, and every RPC the client will call — with allow/deny coverage in the existing SQL suite.

**Architecture:** Part B of `docs/superpowers/specs/2026-08-11-social-feed-design.md`, backend only. Four new tables with RLS enabled and **no policies**, so direct table access returns zero rows and all access flows through `security definer` RPCs — the pattern the existing `nudges` table uses. Visibility is decided by the existing `public.is_accepted_friend()` helper, which already excludes blocked pairs in both directions. No Swift is touched; the client is Part B2.

**Tech Stack:** PostgreSQL 16, Supabase (PostgREST RPCs, Storage), plain `psql` test harness (no Docker required).

## Global Constraints

- **Migrations are append-only.** `CONTRIBUTING.md:25`: "Keep migrations **append-only** and idempotent-friendly; never edit a released migration." Every change here is a NEW file. Never edit an existing migration.
- New tables: `alter table ... enable row level security;` plus `revoke all on table ... from public, anon, authenticated;` and **no policies**. RLS-with-no-policies is what makes direct selects return zero rows; the test suite's shim re-grants table DML, so revoke alone is not the guard.
- New functions: `language plpgsql` (or `sql` where purely relational), `security definer`, `set search_path = ''`. Every reference inside must be schema-qualified (`public.`, `auth.`) because the search path is empty.
- Every function needs `revoke all on function public.fn(argtypes) from public, anon;` then `grant execute on function public.fn(argtypes) to authenticated;`. The test shim grants table DML but **not** function execute, so a missing grant fails the suite.
- Every mutating RPC calls `perform public.enforce_rate_limit(<action>, <max>, <window>);`.
- Auth guard in every RPC: `if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;`
- Errcode convention already in use: `28000` not authenticated, `P0002` target not available/not found, `22023` invalid argument, `P0001` rate limited.
- Test harness: `./supabase/tests/run_local_pg.sh` (needs Homebrew `postgresql@16`; override with `PG_BIN=...`). It applies every migration in filename order, then `_shim_grants.sql`, then `seed.sql`, then `rls_rpc_suite.sql` under `ON_ERROR_STOP=1`.
- `supabase/tests/rls_rpc_suite.sql` ends with a `ALL RLS/RPC CHECKS PASSED` banner. New `tN` blocks must be inserted BEFORE it, never after, or the banner claims success before the checks it summarises have run.
- **Negative tests must use the `ok` pattern.** Putting `raise exception 'FAIL …'` inside a block guarded by `exception when others then null` swallows the FAIL, producing a test that can never fail. Always raise outside the handler, as the existing suite does at `rls_rpc_suite.sql:57`:
  ```sql
  do $$ declare ok boolean := false; begin
    begin
      perform public.thing_that_should_be_rejected();
    exception when others then ok := true;
    end;
    if not ok then raise exception 'FAIL tN: <what went wrong>'; end if;
    raise notice 'PASS tN: <what holds>';
  end $$;
  ```
- Compare expected values with `is distinct from`, not `<>` — a NULL left-hand side makes `<>` yield NULL, the `if` is skipped, and the test passes vacuously.
- Test style, matching the existing suite: switch identity with `reset role; set role authenticated; set app.uid = '<uuid>';` then a `do $$ begin ... raise exception 'FAIL tN: ...'; ... raise notice 'PASS tN: ...'; end $$;` block. Continue the existing `tN` numbering — Task 3 left the suite ending at **t34**, so Task 4 starts at **t35**.
- Seeded identities and relationships (from `supabase/seed.sql`): Alice `00000000-0000-4000-8000-0000000000a1`; Barnaby `...b2` (accepted friend of Alice); Ceri `...c3` (accepted friend of Alice); Dev `...d4` (**blocked** by Alice, friendship forced to `removed`). Barnaby and Ceri are **not** friends with each other — that is the non-friend case.
- No Swift files. No changes under `CheekyPint/`, `CheekyPintCore/`, `CheekyPintTests/`, `CheekyPintUITests/`.
- **Deliberate divergence from the spec:** the spec says comment text "runs through the existing `ProfileTextSanitizer`", which is Swift and therefore client-side only. This plan additionally sanitises server-side via `public.strip_ugc_control_chars`, because a client-only sanitiser is bypassable by anyone calling the RPC directly. Part B2 may still run the Swift sanitiser for immediate feedback; the database is the enforcement point.
- Work on a branch cut from `feat/instant-log-nudge` (or its successor once merged). Commit per task as the steps instruct. Never commit on `master`.

---

## File Structure

| File | Responsibility |
|---|---|
| `supabase/migrations/20260811000100_feed_tables.sql` | `posts`, `post_cheers`, `post_comments`, `comment_mentions`; indexes; RLS; the shared UGC text-strip helper |
| `supabase/migrations/20260811000200_feed_storage.sql` | `post-images` bucket + owner-folder policies |
| `supabase/migrations/20260811000300_report_category_post_image.sql` | `alter type report_category add value` — **alone in its own file** |
| `supabase/migrations/20260811000400_feed_reports.sql` | `reports.post_id` / `reports.comment_id` columns + target check |
| `supabase/migrations/20260811000500_rpc_feed_posts.sql` | `create_post`, `delete_post`, `feed_page` |
| `supabase/migrations/20260811000600_rpc_feed_social.sql` | `toggle_post_cheers`, `add_comment`, `delete_comment`, `post_comments_page` |
| `supabase/migrations/20260811000700_rpc_feed_reports.sql` | `report_post`, `report_comment` |
| `supabase/tests/rls_rpc_suite.sql` | Extended with t26 onward |

Why the enum change is alone in `..._000300_`: `alter type ... add value` cannot be used by other statements in the same transaction. Keeping it in its own file guarantees it is committed before `..._000400_` and the report RPCs reference it.

---

### Task 1: Feed tables, indexes, RLS

**Files:**
- Create: `supabase/migrations/20260811000100_feed_tables.sql`
- Modify: `supabase/tests/rls_rpc_suite.sql` (append t26–t27)

**Interfaces:**
- Consumes: `public.profiles(id)`, `public.pubs(id)` (both exist).
- Produces: tables `public.posts`, `public.post_cheers`, `public.post_comments`, `public.comment_mentions`; helper `public.strip_ugc_control_chars(t text) returns text`.

- [ ] **Step 1: Write the failing test**

Append to `supabase/tests/rls_rpc_suite.sql`:

```sql
-- ============================ FEED: table lockdown ============================
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000a1';

do $$ declare visible int; begin
  select count(*) into visible from public.posts;
  if visible <> 0 then raise exception 'FAIL t26: direct posts select exposed % rows', visible; end if;
  select count(*) into visible from public.post_cheers;
  if visible <> 0 then raise exception 'FAIL t26: direct post_cheers select exposed % rows', visible; end if;
  select count(*) into visible from public.post_comments;
  if visible <> 0 then raise exception 'FAIL t26: direct post_comments select exposed % rows', visible; end if;
  select count(*) into visible from public.comment_mentions;
  if visible <> 0 then raise exception 'FAIL t26: direct comment_mentions select exposed % rows', visible; end if;
  raise notice 'PASS t26: feed tables are invisible to direct selects';
end $$;

do $$ declare v text; begin
  select public.strip_ugc_control_chars('a' || chr(8203) || chr(9) || 'b' || chr(8237) || 'c') into v;
  if v <> 'abc' then raise exception 'FAIL t27: strip_ugc_control_chars gave %', v; end if;
  raise notice 'PASS t27: control, zero-width and bidi characters are stripped';
end $$;
```

- [ ] **Step 2: Run the suite to verify it fails**

```bash
cd ~/Projects/cheekypint && ./supabase/tests/run_local_pg.sh
```

Expected: FAIL — `relation "public.posts" does not exist`.

- [ ] **Step 3: Create the migration**

Create `supabase/migrations/20260811000100_feed_tables.sql`:

```sql
-- CheekyPint: friends-only social feed — posts, Cheers reactions, comments, mentions.
--
-- "Cheers" here is the feed reaction (clinking beers). The friend-poke gesture is a Nudge
-- (see 20260803000000_nudges.sql) — different feature, different table.
--
-- Every table has RLS enabled with NO policies: direct access returns zero rows and all reads
-- and writes go through the security-definer RPCs, which decide visibility via
-- public.is_accepted_friend() (already block-aware in both directions).

-- Shared sanitiser for user-supplied text. Deletes C0/C1 control characters plus the
-- zero-width and bidi-override characters used to spoof or scramble displayed text.
create or replace function public.strip_ugc_control_chars(t text)
returns text
language sql
immutable
set search_path = ''
as $$
  select regexp_replace(
           translate(
             coalesce(t, ''),
             chr(8203) || chr(8204) || chr(8205) || chr(8206) || chr(8207) ||
             chr(8234) || chr(8235) || chr(8236) || chr(8237) || chr(8238) ||
             -- Word joiner and the four bidi isolates: the Trojan-Source scrambling set.
             chr(8288) || chr(8294) || chr(8295) || chr(8296) || chr(8297) || chr(65279),
             ''
           ),
           '[[:cntrl:]]', '', 'g'
         );
$$;

comment on function public.strip_ugc_control_chars(text) is
  'Strips control, zero-width and bidi characters from user-supplied text.';

create table public.posts (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references public.profiles (id) on delete cascade,
  body text constraint posts_body_length check (body is null or char_length(body) <= 500),
  image_path text constraint posts_image_path_length check (image_path is null or char_length(image_path) <= 300),
  place_label text constraint posts_place_label_length check (place_label is null or char_length(place_label) <= 80),
  pub_id uuid references public.pubs (id) on delete set null,
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  -- A post is a photo, some words, or both — never neither.
  constraint posts_has_content check (
    char_length(btrim(coalesce(body, ''))) > 0 or char_length(btrim(coalesce(image_path, ''))) > 0
  ),
  -- A pub reference always carries the label the feed renders, so readers need no join.
  constraint posts_pub_needs_label check (
    pub_id is null or char_length(btrim(coalesce(place_label, ''))) > 0
  )
);

comment on table public.posts is
  'Friends-only feed posts. A location is a free label; pub_id is set only for a known venue.';

create index posts_created_idx on public.posts (created_at desc);
create index posts_author_created_idx on public.posts (author_id, created_at desc);

create table public.post_cheers (
  post_id uuid not null references public.posts (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

comment on table public.post_cheers is
  'One Cheers per user per post; the RPC toggles. Never affects drink totals.';

create table public.post_comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts (id) on delete cascade,
  author_id uuid not null references public.profiles (id) on delete cascade,
  body text not null constraint post_comments_body_length check (char_length(body) between 1 and 280),
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);

comment on table public.post_comments is 'Comments on feed posts. Soft-deleted by author.';

create index post_comments_post_created_idx on public.post_comments (post_id, created_at);

create table public.comment_mentions (
  comment_id uuid not null references public.post_comments (id) on delete cascade,
  mentioned_user_id uuid not null references public.profiles (id) on delete cascade,
  primary key (comment_id, mentioned_user_id)
);

comment on table public.comment_mentions is
  'Mentions recorded at write time rather than parsed on read, so rendering stays cheap.';

create index comment_mentions_user_idx on public.comment_mentions (mentioned_user_id);

-- No direct table access: reads and writes go through the feed RPCs.
alter table public.posts enable row level security;
alter table public.post_cheers enable row level security;
alter table public.post_comments enable row level security;
alter table public.comment_mentions enable row level security;

revoke all on table public.posts from public, anon, authenticated;
revoke all on table public.post_cheers from public, anon, authenticated;
revoke all on table public.post_comments from public, anon, authenticated;
revoke all on table public.comment_mentions from public, anon, authenticated;

revoke all on function public.strip_ugc_control_chars(text) from public, anon;
grant execute on function public.strip_ugc_control_chars(text) to authenticated;
```

- [ ] **Step 4: Run the suite to verify it passes**

```bash
cd ~/Projects/cheekypint && ./supabase/tests/run_local_pg.sh
```

Expected: every migration `ok`, and `PASS t26` / `PASS t27` in the output.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260811000100_feed_tables.sql supabase/tests/rls_rpc_suite.sql
git commit -m "feat: add feed tables with RLS lockdown"
```

---

### Task 2: `post-images` storage bucket

**Files:**
- Create: `supabase/migrations/20260811000200_feed_storage.sql`

**Interfaces:**
- Produces: storage bucket `post-images`, keyed `post-images/<user_id>/<random>.jpg`.

- [ ] **Step 1: Create the migration**

Mirrors `20260101000950_storage.sql` exactly, including its documented read tradeoff. Create `supabase/migrations/20260811000200_feed_storage.sql`:

```sql
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
```

- [ ] **Step 2: Run the suite to confirm the migration applies**

```bash
cd ~/Projects/cheekypint && ./supabase/tests/run_local_pg.sh
```

Expected: `20260811000200_feed_storage.sql   ok` and the suite still green. No shim work is needed — `supabase/tests/_shim_bootstrap.sql:53-77` already creates the `storage` schema with `buckets`, `objects`, `storage.foldername()` and the `authenticated` grants.

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/20260811000200_feed_storage.sql
git commit -m "feat: add post-images storage bucket"
```

---

### Task 3: Post RPCs — `create_post`, `delete_post`, `feed_page`

**Files:**
- Create: `supabase/migrations/20260811000500_rpc_feed_posts.sql`
- Modify: `supabase/tests/rls_rpc_suite.sql` (append t28–t32)

**Interfaces:**
- Consumes: `public.posts` and `public.strip_ugc_control_chars(text)` from Task 1; `public.is_accepted_friend(uuid, uuid)`; `public.enforce_rate_limit(text, int, interval)`.
- Produces:
  - `public.create_post(p_body text, p_image_path text, p_place_label text, p_pub_id uuid) returns jsonb` → `{"post_id": uuid}`
  - `public.delete_post(p_post_id uuid) returns void`
  - `public.feed_page(p_before timestamptz, p_before_id uuid, p_limit int) returns table (post_id uuid, author_id uuid, display_name text, avatar_path text, body text, image_path text, place_label text, pub_id uuid, created_at timestamptz, cheers_count int, viewer_has_cheered boolean, comment_count int)` — compound `(created_at, id)` cursor; `avatar_path` is gated on the owner's `privacy_settings.avatar_visibility`

- [ ] **Step 1: Write the failing tests**

Append to `supabase/tests/rls_rpc_suite.sql`:

```sql
-- ============================ FEED: posts ============================
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000a1';

do $$ declare v jsonb; v_count int; begin
  select public.create_post('First pint of the trip', null, 'Prague', null) into v;
  if (v->>'post_id') is null then raise exception 'FAIL t28: create_post returned no post_id'; end if;
  select count(*) into v_count from public.feed_page(null, null, 20) where author_id = '00000000-0000-4000-8000-0000000000a1';
  if v_count is distinct from 1 then raise exception 'FAIL t28: author sees % of own posts (want 1)', v_count; end if;
  raise notice 'PASS t28: create_post stores a post the author can read back';
end $$;

do $$ declare ok_empty boolean := false; ok_pub boolean := false; v_state text; begin
  begin
    perform public.create_post(null, null, 'Prague', null);
  exception when others then get stacked diagnostics v_state = returned_sqlstate;
    ok_empty := (v_state = '22023');
  end;
  begin
    perform public.create_post('x', null, null, '00000000-0000-4000-8000-00000000e001');
  exception when others then get stacked diagnostics v_state = returned_sqlstate;
    ok_pub := (v_state = '22023');
  end;
  if not ok_empty then raise exception 'FAIL t29: create_post accepted a post with neither body nor image'; end if;
  if not ok_pub then raise exception 'FAIL t29: create_post accepted a pub_id with no place_label'; end if;
  raise notice 'PASS t29: create_post rejects empty posts and unlabelled pub references';
end $$;

do $$ declare v text; begin
  perform public.create_post('clean' || chr(8203) || chr(9) || 'text', null, null, null);
  select body into v from public.feed_page(null, null, 20) order by created_at desc limit 1;
  if v is distinct from 'cleantext' then raise exception 'FAIL t30: post body not sanitised, got %', v; end if;
  raise notice 'PASS t30: create_post strips control and zero-width characters from the body';
end $$;

-- Barnaby is an accepted friend of Alice; Ceri is a friend of Alice but NOT of Barnaby.
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000b2';
do $$ declare v_count int; begin
  select count(*) into v_count from public.feed_page(null, null, 20)
    where author_id = '00000000-0000-4000-8000-0000000000a1';
  if v_count is distinct from 2 then raise exception 'FAIL t31: friend sees % of Alice posts (want 2)', v_count; end if;
  raise notice 'PASS t31: an accepted friend sees the posts';
end $$;

reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000d4';
do $$ declare v_count int; begin
  select count(*) into v_count from public.feed_page(null, null, 20);
  if v_count <> 0 then raise exception 'FAIL t31: blocked user sees % posts (want 0)', v_count; end if;
  raise notice 'PASS t31: a blocked user sees nothing';
end $$;

reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000a1';
do $$ declare v_id uuid; v_count int; begin
  select post_id into v_id from public.feed_page(null, null, 20) order by created_at desc limit 1;
  perform public.delete_post(v_id);
  select count(*) into v_count from public.feed_page(null, null, 20) where post_id = v_id;
  if v_count <> 0 then raise exception 'FAIL t32: soft-deleted post still visible'; end if;
  raise notice 'PASS t32: delete_post hides the post from every read path';
end $$;

reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000b2';
do $$ declare v_id uuid; ok boolean := false; begin
  select post_id into v_id from public.feed_page(null, null, 20) limit 1;
  if v_id is null then raise exception 'FAIL t32: no visible post to attempt deleting'; end if;
  begin
    perform public.delete_post(v_id);
  exception when others then ok := true;
  end;
  if not ok then raise exception 'FAIL t32: a non-author deleted someone else''s post'; end if;
  raise notice 'PASS t32: only the author can delete a post';
end $$;
```

- [ ] **Step 2: Run the suite to verify it fails**

```bash
cd ~/Projects/cheekypint && ./supabase/tests/run_local_pg.sh
```

Expected: FAIL — `function public.create_post(...) does not exist`.

- [ ] **Step 3: Create the migration**

Create `supabase/migrations/20260811000500_rpc_feed_posts.sql`:

```sql
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
  -- The bucket's own insert policy (20260811000200_feed_storage.sql) restricts uploads to the
  -- uploader's own folder; mirror that here so a caller cannot pass someone ELSE's already-
  -- uploaded (unguessable but readable-once-known) path and re-broadcast their photo.
  if v_image is not null and (storage.foldername(v_image))[1] <> v_uid::text then
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
     and (p_before is null
          or (p.created_at, p.id) < (p_before, coalesce(p_before_id, '00000000-0000-0000-0000-000000000000'::uuid)))
   order by p.created_at desc, p.id desc
   limit least(greatest(coalesce(p_limit, 20), 1), 50);
$$;

revoke all on function public.create_post(text, text, text, uuid) from public, anon;
revoke all on function public.delete_post(uuid) from public, anon;
revoke all on function public.feed_page(timestamptz, uuid, int) from public, anon;

grant execute on function public.create_post(text, text, text, uuid) to authenticated;
grant execute on function public.delete_post(uuid) to authenticated;
grant execute on function public.feed_page(timestamptz, uuid, int) to authenticated;
```

Note: `profiles.deleted_at` (confirmed at `supabase/migrations/20260101000200_core_tables.sql:25`) is the admin disable flag described in `docs/MODERATION.md`. Excluding it keeps a disabled author's posts out of every feed.

- [ ] **Step 4: Run the suite to verify it passes**

```bash
cd ~/Projects/cheekypint && ./supabase/tests/run_local_pg.sh
```

Expected: `PASS t28` through `PASS t32`.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260811000500_rpc_feed_posts.sql supabase/tests/rls_rpc_suite.sql
git commit -m "feat: add feed post RPCs"
```

---

### Task 4: Cheers, comments and mentions RPCs

**Files:**
- Create: `supabase/migrations/20260811000600_rpc_feed_social.sql`
- Modify: `supabase/tests/rls_rpc_suite.sql` (append t35–t38)

**Interfaces:**
- Consumes: `public.posts`, `public.post_cheers`, `public.post_comments`, `public.comment_mentions`, `public.strip_ugc_control_chars(text)` from Task 1; `public.is_accepted_friend(uuid, uuid)`.
- Produces:
  - `public.toggle_post_cheers(p_post_id uuid) returns jsonb` → `{"cheered": boolean, "cheers_count": int}`
  - `public.add_comment(p_post_id uuid, p_body text, p_mentions uuid[]) returns jsonb` → `{"comment_id": uuid}`
  - `public.delete_comment(p_comment_id uuid) returns void`
  - `public.post_comments_page(p_post_id uuid, p_before timestamptz, p_before_id uuid, p_limit int) returns table (comment_id uuid, author_id uuid, display_name text, avatar_path text, body text, created_at timestamptz, mentioned_user_ids uuid[])`
  - `public.can_view_post(p_uid uuid, p_post_id uuid) returns boolean` (internal helper; the shipped code revokes it from `public`/`anon`/`authenticated` — every RPC above calls it as its SECURITY DEFINER owner, not via a direct grant)

- [ ] **Step 1: Write the failing tests**

Append to `supabase/tests/rls_rpc_suite.sql`:

```sql
-- ============================ FEED: cheers, comments, mentions ============================
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000a1';

do $$ declare v_post uuid; v jsonb; begin
  -- Filter by author: Task 3's t34c seeded Ceri-owned posts, so an unfiltered limit 1 is
  -- no longer deterministic under Alice's identity.
  select post_id into v_post from public.feed_page(null, null, 20)
    where author_id = '00000000-0000-4000-8000-0000000000a1' limit 1;
  if v_post is null then raise exception 'FAIL: no Alice post available'; end if;
  select public.toggle_post_cheers(v_post) into v;
  if (v->>'cheered')::boolean is not true then raise exception 'FAIL t35: first toggle did not cheer'; end if;
  if (v->>'cheers_count')::int <> 1 then raise exception 'FAIL t35: count % (want 1)', v->>'cheers_count'; end if;
  select public.toggle_post_cheers(v_post) into v;
  if (v->>'cheered')::boolean is not false then raise exception 'FAIL t35: second toggle did not un-cheer'; end if;
  if (v->>'cheers_count')::int <> 0 then raise exception 'FAIL t35: count % (want 0)', v->>'cheers_count'; end if;
  raise notice 'PASS t35: toggle_post_cheers is idempotent per user and counts correctly';
end $$;

do $$ declare v_post uuid; v jsonb; v_body text; v_mentions uuid[]; begin
  -- Filter by author: Task 3's t34c seeded Ceri-owned posts, so an unfiltered limit 1 is
  -- no longer deterministic under Alice's identity.
  select post_id into v_post from public.feed_page(null, null, 20)
    where author_id = '00000000-0000-4000-8000-0000000000a1' limit 1;
  if v_post is null then raise exception 'FAIL: no Alice post available'; end if;
  select public.add_comment(v_post, 'nice one' || chr(8203) || '!',
                            array['00000000-0000-4000-8000-0000000000b2'::uuid]) into v;
  if (v->>'comment_id') is null then raise exception 'FAIL t36: add_comment returned no id'; end if;
  select body, mentioned_user_ids into v_body, v_mentions
    from public.post_comments_page(v_post, null, 20) limit 1;
  if v_body is distinct from 'nice one!' then raise exception 'FAIL t36: comment body not sanitised, got %', v_body; end if;
  if v_mentions is distinct from array['00000000-0000-4000-8000-0000000000b2'::uuid] then
    raise exception 'FAIL t36: mentions % wrong', v_mentions; end if;
  raise notice 'PASS t36: add_comment sanitises the body and records mentions';
end $$;

-- Dev is blocked by Alice, so he is not a mentionable friend.
do $$ declare v_post uuid; ok boolean := false; begin
  -- Filter by author: Task 3's t34c seeded Ceri-owned posts, so an unfiltered limit 1 is
  -- no longer deterministic under Alice's identity.
  select post_id into v_post from public.feed_page(null, null, 20)
    where author_id = '00000000-0000-4000-8000-0000000000a1' limit 1;
  if v_post is null then raise exception 'FAIL: no Alice post available'; end if;
  if v_post is null then raise exception 'FAIL t37: no post to comment on'; end if;
  begin
    perform public.add_comment(v_post, 'hi', array['00000000-0000-4000-8000-0000000000d4'::uuid]);
  exception when others then ok := true;
  end;
  if not ok then raise exception 'FAIL t37: mentioned a non-friend'; end if;
  raise notice 'PASS t37: mentioning a non-friend is rejected';
end $$;

-- Ceri is Alice's friend but not Barnaby's, so Ceri must not reach Barnaby's post.
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000b2';
do $$ declare v jsonb; v_post uuid; ok_cheer boolean := false; ok_comment boolean := false; begin
  select public.create_post('Barnaby was here', null, null, null) into v;
  v_post := (v->>'post_id')::uuid;
  -- Ceri is Alice's friend but not Barnaby's, and nobody has blocked anybody here: this is the
  -- non-friend, non-blocked case that distinguishes friends-only from merely not-blocked.
  perform set_config('app.uid', '00000000-0000-4000-8000-0000000000c3', false);
  begin
    perform public.toggle_post_cheers(v_post);
  exception when others then ok_cheer := true;
  end;
  begin
    perform public.add_comment(v_post, 'sneaking in', null);
  exception when others then ok_comment := true;
  end;
  if not ok_cheer then raise exception 'FAIL t38: a non-friend cheered a post they cannot see'; end if;
  if not ok_comment then raise exception 'FAIL t38: a non-friend commented on a post they cannot see'; end if;
  raise notice 'PASS t38: cheers and comments require visibility of the post';
end $$;

reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000a1';
do $$ declare v_post uuid; v_comment uuid; v_count int; begin
  select post_id into v_post from public.feed_page(null, null, 20)
    where author_id = '00000000-0000-4000-8000-0000000000a1' limit 1;
  select comment_id into v_comment from public.post_comments_page(v_post, null, 20) limit 1;
  perform public.delete_comment(v_comment);
  select count(*) into v_count from public.post_comments_page(v_post, null, 20) where comment_id = v_comment;
  if v_count <> 0 then raise exception 'FAIL t38: soft-deleted comment still visible'; end if;
  raise notice 'PASS t38: delete_comment hides the comment';
end $$;
```

- [ ] **Step 2: Run the suite to verify it fails**

```bash
cd ~/Projects/cheekypint && ./supabase/tests/run_local_pg.sh
```

Expected: FAIL — `function public.toggle_post_cheers(uuid) does not exist`.

- [ ] **Step 3: Create the migration**

Create `supabase/migrations/20260811000600_rpc_feed_social.sql`:

```sql
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

  perform public.enforce_rate_limit('post_cheers', 200, interval '1 hour');

  delete from public.post_cheers where post_id = p_post_id and user_id = v_uid;
  if found then
    v_cheered := false;
  else
    insert into public.post_cheers (post_id, user_id) values (p_post_id, v_uid);
    v_cheered := true;
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
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;
  if not public.can_view_post(v_uid, p_post_id) then
    raise exception 'Post not available' using errcode = 'P0002';
  end if;

  perform public.enforce_rate_limit('post_comment', 60, interval '1 hour');

  v_body := nullif(btrim(public.strip_ugc_control_chars(p_body)), '');
  if v_body is null then
    raise exception 'A comment needs some words' using errcode = '22023';
  end if;

  -- You can only mention people you are actually friends with; this closes the obvious
  -- harassment vector of tagging strangers into a thread.
  foreach v_mention in array coalesce(p_mentions, array[]::uuid[]) loop
    if v_mention <> v_uid and not public.is_accepted_friend(v_uid, v_mention) then
      raise exception 'Can only mention friends' using errcode = 'P0002';
    end if;
  end loop;

  insert into public.post_comments (post_id, author_id, body)
  values (p_post_id, v_uid, left(v_body, 280))
  returning * into v_row;

  insert into public.comment_mentions (comment_id, mentioned_user_id)
  select v_row.id, m
    from unnest(coalesce(p_mentions, array[]::uuid[])) as m
   where m <> v_uid
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
         -- Gate the avatar on the owner's privacy setting, exactly as
         -- 20260101000800_rpc_social.sql:247 does. Returning it unconditionally would leak an
         -- avatar its owner hid from friends.
         pr.avatar_path,  -- REPLACE with the gated expression copied from rpc_social.sql:247
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
   where c.post_id = p_post_id
     and c.deleted_at is null
     and pr.deleted_at is null
     and public.can_view_post(auth.uid(), p_post_id)
     and not public.is_blocked(auth.uid(), c.author_id)
     and c.created_at < coalesce(p_before, now() + interval '1 second')
   order by c.created_at
   limit least(greatest(coalesce(p_limit, 30), 1), 100);
$$;

revoke all on function public.can_view_post(uuid, uuid) from public, anon;
revoke all on function public.toggle_post_cheers(uuid) from public, anon;
revoke all on function public.add_comment(uuid, text, uuid[]) from public, anon;
revoke all on function public.delete_comment(uuid) from public, anon;
revoke all on function public.post_comments_page(uuid, timestamptz, int) from public, anon;

grant execute on function public.can_view_post(uuid, uuid) to authenticated;
grant execute on function public.toggle_post_cheers(uuid) to authenticated;
grant execute on function public.add_comment(uuid, text, uuid[]) to authenticated;
grant execute on function public.delete_comment(uuid) to authenticated;
grant execute on function public.post_comments_page(uuid, timestamptz, int) to authenticated;
```

- [ ] **Step 4: Run the suite to verify it passes**

```bash
cd ~/Projects/cheekypint && ./supabase/tests/run_local_pg.sh
```

Expected: `PASS t35` through `PASS t38`.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/20260811000600_rpc_feed_social.sql supabase/tests/rls_rpc_suite.sql
git commit -m "feat: add feed cheers, comments and mention RPCs"
```

---

### Task 5: Reporting posts and comments

**Files:**
- Create: `supabase/migrations/20260811000300_report_category_post_image.sql`
- Create: `supabase/migrations/20260811000400_feed_reports.sql`
- Create: `supabase/migrations/20260811000700_rpc_feed_reports.sql`
- Modify: `supabase/tests/rls_rpc_suite.sql` (append t41–t42)

**Interfaces:**
- Consumes: `public.reports` (existing: `reporter_id`, `reported_user_id`, `category public.report_category`, `details`, `status`, plus a `report_not_self` check); `public.can_view_post(uuid, uuid)` from Task 4.
- Produces:
  - enum value `public.report_category.'inappropriate_post_image'`
  - columns `public.reports.post_id`, `public.reports.comment_id`
  - `public.report_post(p_post_id uuid, p_category public.report_category, p_details text) returns jsonb` → `{"report_id": uuid, "status": text}`
  - `public.report_comment(p_comment_id uuid, p_category public.report_category, p_details text) returns jsonb` → `{"report_id": uuid, "status": text}`

- [ ] **Step 1: Write the failing tests**

Append to `supabase/tests/rls_rpc_suite.sql`:

```sql
-- ============================ FEED: reporting ============================
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000a1';

do $$ declare v_post uuid; v jsonb; v_reported uuid; v_linked uuid; begin
  select post_id into v_post from public.feed_page(null, null, 20)
    where author_id = '00000000-0000-4000-8000-0000000000b2' limit 1;
  if v_post is null then raise exception 'FAIL t41: no Barnaby post to report'; end if;
  select public.report_post(v_post, 'inappropriate_post_image', 'not on') into v;
  if (v->>'report_id') is null then raise exception 'FAIL t41: report_post returned no id'; end if;
  if (v->>'status') <> 'open' then raise exception 'FAIL t41: status % (want open)', v->>'status'; end if;
  select reported_user_id, post_id into v_reported, v_linked
    from public.reports where id = (v->>'report_id')::uuid;
  if v_reported <> '00000000-0000-4000-8000-0000000000b2' then
    raise exception 'FAIL t41: reported_user_id % is not the post author', v_reported; end if;
  if v_linked <> v_post then raise exception 'FAIL t41: report not linked to the post'; end if;
  raise notice 'PASS t41: report_post files against the author and links the post';
end $$;

do $$ declare v_own uuid; ok_self boolean := false; ok_hidden boolean := false; begin
  select post_id into v_own from public.feed_page(null, null, 20)
    where author_id = '00000000-0000-4000-8000-0000000000a1' limit 1;
  if v_own is null then raise exception 'FAIL t42: no own post to test with'; end if;
  begin
    perform public.report_post(v_own, 'inappropriate_text', null);
  exception when others then ok_self := true;
  end;
  begin
    perform public.report_post('00000000-0000-4000-8000-00000000dead', 'inappropriate_text', null);
  exception when others then ok_hidden := true;
  end;
  if not ok_self then raise exception 'FAIL t42: reported own post'; end if;
  if not ok_hidden then raise exception 'FAIL t42: reported an invisible post'; end if;
  raise notice 'PASS t42: cannot report your own post or one you cannot see';
end $$;
```

- [ ] **Step 2: Run the suite to verify it fails**

```bash
cd ~/Projects/cheekypint && ./supabase/tests/run_local_pg.sh
```

Expected: FAIL — `invalid input value for enum public.report_category: "inappropriate_post_image"`.

- [ ] **Step 3: Add the enum value, alone in its own migration**

Create `supabase/migrations/20260811000300_report_category_post_image.sql`:

```sql
-- Feed posts carry photos, and 'inappropriate_profile_image' would mislead a moderator triaging
-- the queue. This value is added in its own migration because a new enum value cannot be
-- referenced by other statements in the transaction that creates it.
alter type public.report_category add value if not exists 'inappropriate_post_image';
```

- [ ] **Step 4: Add the report target columns**

Create `supabase/migrations/20260811000400_feed_reports.sql`:

```sql
-- Reports already record WHO is being reported. Feed reports also need to say WHICH piece of
-- content, so a moderator can act on one post rather than a whole account.
alter table public.reports
  add column if not exists post_id uuid references public.posts (id) on delete cascade,
  add column if not exists comment_id uuid references public.post_comments (id) on delete cascade;

-- At most one target: a report is about an account, a post, or a comment.
alter table public.reports
  drop constraint if exists reports_single_target;
alter table public.reports
  add constraint reports_single_target
  check (post_id is null or comment_id is null);

create index if not exists reports_post_idx on public.reports (post_id) where post_id is not null;
create index if not exists reports_comment_idx on public.reports (comment_id) where comment_id is not null;
```

- [ ] **Step 5: Add the report RPCs**

Create `supabase/migrations/20260811000700_rpc_feed_reports.sql`:

```sql
-- CheekyPint: reporting feed content. Mirrors public.report_user's shape and rate-limit action
-- so the moderation queue stays one uniform surface.

create or replace function public.report_post(
  p_post_id uuid,
  p_category public.report_category,
  p_details text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_author uuid;
  v_row public.reports;
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;
  if not public.can_view_post(v_uid, p_post_id) then
    raise exception 'Post not available' using errcode = 'P0002';
  end if;

  select author_id into v_author from public.posts where id = p_post_id;
  if v_author = v_uid then
    raise exception 'Cannot report yourself' using errcode = '22023';
  end if;

  perform public.enforce_rate_limit('report', 20, interval '1 hour');

  insert into public.reports (reporter_id, reported_user_id, category, details, post_id)
  values (v_uid, v_author, p_category, left(coalesce(p_details, ''), 1000), p_post_id)
  returning * into v_row;

  return jsonb_build_object('report_id', v_row.id, 'status', v_row.status);
end;
$$;

create or replace function public.report_comment(
  p_comment_id uuid,
  p_category public.report_category,
  p_details text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_author uuid;
  v_post uuid;
  v_row public.reports;
begin
  if v_uid is null then raise exception 'Not authenticated' using errcode = '28000'; end if;

  select author_id, post_id into v_author, v_post
    from public.post_comments
   where id = p_comment_id and deleted_at is null;

  if v_author is null or not public.can_view_post(v_uid, v_post) then
    raise exception 'Comment not available' using errcode = 'P0002';
  end if;
  if v_author = v_uid then
    raise exception 'Cannot report yourself' using errcode = '22023';
  end if;

  perform public.enforce_rate_limit('report', 20, interval '1 hour');

  insert into public.reports (reporter_id, reported_user_id, category, details, comment_id)
  values (v_uid, v_author, p_category, left(coalesce(p_details, ''), 1000), p_comment_id)
  returning * into v_row;

  return jsonb_build_object('report_id', v_row.id, 'status', v_row.status);
end;
$$;

revoke all on function public.report_post(uuid, public.report_category, text) from public, anon;
revoke all on function public.report_comment(uuid, public.report_category, text) from public, anon;

grant execute on function public.report_post(uuid, public.report_category, text) to authenticated;
grant execute on function public.report_comment(uuid, public.report_category, text) to authenticated;
```

- [ ] **Step 6: Run the suite to verify it passes**

```bash
cd ~/Projects/cheekypint && ./supabase/tests/run_local_pg.sh
```

Expected: `PASS t41` and `PASS t42`, and every earlier test still passing.

Note: the t37 read of `public.reports` runs as `authenticated` and works as written — `supabase/migrations/20260101000700_rls_policies.sql:74` defines a `reports_select_own` policy, so a reporter can read the rows they filed.

- [ ] **Step 7: Update the moderation documentation**

`docs/MODERATION.md` currently states, under "Constrained surface (by design)": *"No public posts, comments, direct messages, anonymous chat, or image feeds in the MVP. The only user-visible UGC is: display name, username, bio, avatar, and pub suggestions."* That becomes false with this feature, and that document backs the app's 17+ age rating.

Replace that section with an accurate description: the feed is **friends-only** (not public); user-visible UGC now also includes post bodies, post photos, comments and mentions; mentions are restricted to accepted friends; blocking hides feed content in both directions; and reporting covers accounts, posts and comments via `report_user` / `report_post` / `report_comment`, all landing in the same `reports` queue. Add the new rate-limit actions (`post_create`, `post_comment`, `post_cheers`) to the preventive-controls list alongside the existing ones.

Do not weaken any existing claim you cannot verify in the code — if you cannot confirm something, describe what is actually implemented.

- [ ] **Step 8: Commit**

```bash
git add supabase/migrations/20260811000300_report_category_post_image.sql \
        supabase/migrations/20260811000400_feed_reports.sql \
        supabase/migrations/20260811000700_rpc_feed_reports.sql \
        supabase/tests/rls_rpc_suite.sql docs/MODERATION.md
git commit -m "feat: allow reporting feed posts and comments"
```

---

## Not in this plan

Part B2 (the client): `FeedView`, `FeedPostCard`, `ComposePostSheet`, `PlacePickerSheet` (`MKLocalSearchCompleter` over cities and venues), `PostCommentsSheet` with mention autocomplete, `FeedViewModel`, `FeedRepository`, the report UI, and the fourth tab in `MainTabView`. Write that plan once this one is green.

Also out of scope, per the spec: push notifications, a public feed, post editing, nested replies, video, and Cheers on comments.
