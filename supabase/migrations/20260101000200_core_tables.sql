-- CheekyPint schema — 02. Core tables: profiles, privacy_settings, friend_tokens

-- profiles ------------------------------------------------------------------------------
-- One row per auth user. `city`/`country_code` are BROAD, user-entered location only —
-- never a street address, never inferred from activity.
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null default 'New regular'
    constraint display_name_length check (char_length(display_name) between 1 and 40),
  username extensions.citext unique
    constraint username_format check (
      username is null or username::text ~ '^[a-z][a-z0-9_]{2,19}$'
    ),
  bio text constraint bio_length check (bio is null or char_length(bio) <= 160),
  avatar_path text,
  city text constraint city_length check (city is null or char_length(city) <= 60),
  country_code text constraint country_code_format check (
    country_code is null or country_code ~ '^[A-Z]{2}$'
  ),
  legal_age_confirmed_at timestamptz,
  timezone text not null default 'UTC',
  locale text not null default 'en_GB',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

comment on table public.profiles is 'User profiles; city/country are broad, optional, user-entered locations only.';
comment on column public.profiles.legal_age_confirmed_at is 'Set when the user confirms they meet their local legal drinking age.';

create index profiles_username_idx on public.profiles (username) where username is not null;
create index profiles_active_idx on public.profiles (id) where deleted_at is null;

create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- privacy_settings ----------------------------------------------------------------------
-- One row per user; every shareable surface has its own switch.
create table public.privacy_settings (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  profile_visibility public.visibility not null default 'friends',
  avatar_visibility public.visibility not null default 'friends',
  city_visibility public.visibility not null default 'private',
  session_total_visibility public.visibility not null default 'friends',
  weekly_total_visibility public.visibility not null default 'friends',
  monthly_total_visibility public.visibility not null default 'friends',
  yearly_total_visibility public.visibility not null default 'friends',
  favourite_pubs_visibility public.visibility not null default 'private',
  shared_sessions_visibility public.visibility not null default 'friends',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.privacy_settings is 'Per-user field visibility. Defaults match the recommended onboarding configuration.';

create trigger privacy_settings_set_updated_at
  before update on public.privacy_settings
  for each row execute function public.set_updated_at();

-- friend_tokens -------------------------------------------------------------------------
-- Only the SHA-256 hash of the raw token is stored. The raw token exists solely on the
-- owner's device and inside their QR image. Tokens are revocable and can expire.
create table public.friend_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  token_hash text not null unique,
  expires_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);

comment on table public.friend_tokens is 'Revocable friend QR tokens; only the hash is stored server-side.';

-- Fast lookup of the caller's currently-active token.
create index friend_tokens_active_idx
  on public.friend_tokens (user_id)
  where revoked_at is null;
