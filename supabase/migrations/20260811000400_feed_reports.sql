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
