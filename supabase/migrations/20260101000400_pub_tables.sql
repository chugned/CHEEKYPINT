-- CheekyPint schema — 04. Pubs, sessions, membership

-- pubs ----------------------------------------------------------------------------------
-- A pub is a PUBLIC business location. Coordinates are public data; a user's *visits* are
-- private (enforced on pint_entries, not here).
create table public.pubs (
  id uuid primary key default gen_random_uuid(),
  external_source public.pub_source,
  external_identifier text,
  name text not null constraint pub_name_length check (char_length(name) between 1 and 120),
  formatted_address text,
  city text,
  country_code text constraint pub_country_code_format check (
    country_code is null or country_code ~ '^[A-Z]{2}$'
  ),
  latitude double precision not null constraint pub_lat_range check (latitude between -90 and 90),
  longitude double precision not null constraint pub_lng_range check (longitude between -180 and 180),
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.pubs is 'Public pub records. Coordinates are public; user visit history is private.';

-- De-duplicate MapKit-sourced pubs by their external identifier.
create unique index pubs_external_identity_idx
  on public.pubs (external_source, external_identifier)
  where external_source is not null and external_identifier is not null;

create index pubs_city_idx on public.pubs (city);

create trigger pubs_set_updated_at
  before update on public.pubs
  for each row execute function public.set_updated_at();

-- pub_sessions --------------------------------------------------------------------------
-- A temporary gathering. Only the HASH of the join token is stored, like friend tokens.
create table public.pub_sessions (
  id uuid primary key default gen_random_uuid(),
  pub_id uuid references public.pubs (id) on delete set null,
  host_user_id uuid not null references public.profiles (id) on delete cascade,
  name text constraint session_name_length check (name is null or char_length(name) <= 80),
  status public.session_status not null default 'active',
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  join_token_hash text unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint session_end_after_start check (ended_at is null or ended_at >= started_at)
);

comment on table public.pub_sessions is 'Temporary pub gatherings; participation is always explicit, never inferred.';

create index pub_sessions_host_idx on public.pub_sessions (host_user_id);
create index pub_sessions_active_idx on public.pub_sessions (status) where status = 'active';

create trigger pub_sessions_set_updated_at
  before update on public.pub_sessions
  for each row execute function public.set_updated_at();

-- session_members -----------------------------------------------------------------------
create table public.session_members (
  session_id uuid not null references public.pub_sessions (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  role public.session_member_role not null default 'member',
  joined_at timestamptz not null default now(),
  left_at timestamptz,
  primary key (session_id, user_id)
);

comment on table public.session_members is 'Explicit session membership. A user must actively join.';

create index session_members_user_idx on public.session_members (user_id);
create index session_members_active_idx on public.session_members (session_id) where left_at is null;
