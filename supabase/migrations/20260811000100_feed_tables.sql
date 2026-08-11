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
             chr(8234) || chr(8235) || chr(8236) || chr(8237) || chr(8238) || chr(65279),
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
  constraint posts_has_content check (body is not null or image_path is not null),
  -- A pub reference always carries the label the feed renders, so readers need no join.
  constraint posts_pub_needs_label check (pub_id is null or place_label is not null)
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

create index post_cheers_post_idx on public.post_cheers (post_id);

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
