-- CheekyPint schema — 03. Social tables: friendships, blocks, reports

-- friendships ---------------------------------------------------------------------------
-- Directed edge (requester → addressee). A canonical (least, greatest) pair is stored in
-- generated columns so a single partial unique index prevents duplicate *active*
-- relationships in either direction.
create table public.friendships (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.profiles (id) on delete cascade,
  addressee_id uuid not null references public.profiles (id) on delete cascade,
  status public.friendship_status not null default 'pending',
  requested_at timestamptz not null default now(),
  responded_at timestamptz,
  updated_at timestamptz not null default now(),
  user_low uuid generated always as (least(requester_id, addressee_id)) stored,
  user_high uuid generated always as (greatest(requester_id, addressee_id)) stored,
  constraint friendship_not_self check (requester_id <> addressee_id)
);

comment on table public.friendships is 'Directed friendship edges; only accepted rows grant mutual visibility.';

-- At most one live (pending or accepted) relationship per unordered pair.
create unique index friendships_unique_active_pair
  on public.friendships (user_low, user_high)
  where status in ('pending', 'accepted');

create index friendships_requester_idx on public.friendships (requester_id);
create index friendships_addressee_idx on public.friendships (addressee_id);
create index friendships_accepted_low_idx on public.friendships (user_low) where status = 'accepted';
create index friendships_accepted_high_idx on public.friendships (user_high) where status = 'accepted';

create trigger friendships_set_updated_at
  before update on public.friendships
  for each row execute function public.set_updated_at();

-- blocks --------------------------------------------------------------------------------
-- A block overrides every friendship/leaderboard/session rule. Directed row, symmetric
-- effect on visibility.
create table public.blocks (
  blocker_id uuid not null references public.profiles (id) on delete cascade,
  blocked_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  constraint block_not_self check (blocker_id <> blocked_id)
);

comment on table public.blocks is 'Blocks override all other visibility. Effect is symmetric even though the row is directed.';

create index blocks_blocked_idx on public.blocks (blocked_id);

-- reports -------------------------------------------------------------------------------
create table public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references public.profiles (id) on delete cascade,
  reported_user_id uuid not null references public.profiles (id) on delete cascade,
  category public.report_category not null,
  details text constraint report_details_length check (details is null or char_length(details) <= 1000),
  status public.report_status not null default 'open',
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  constraint report_not_self check (reporter_id <> reported_user_id)
);

comment on table public.reports is 'Moderation report queue for admin review.';

create index reports_status_idx on public.reports (status, created_at);
create index reports_reported_idx on public.reports (reported_user_id);
