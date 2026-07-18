-- CheekyPint schema — 05. Pint entries, clinks, pub preferences

-- pint_entries --------------------------------------------------------------------------
-- The atomic diary unit. `occurred_at` is user-adjustable; `created_at` is the server's
-- own authoritative timestamp (we never trust the device clock alone). Idempotency is
-- enforced by a unique (user_id, idempotency_key).
create table public.pint_entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  pub_id uuid references public.pubs (id) on delete set null,
  session_id uuid references public.pub_sessions (id) on delete set null,
  occurred_at timestamptz not null default now(),
  serving_type public.serving_type not null default 'pint',
  volume_ml double precision constraint volume_ml_range check (
    volume_ml is null or (volume_ml > 0 and volume_ml <= 5000)
  ),
  alcohol_free boolean not null default false,
  private_note text constraint private_note_length check (
    private_note is null or char_length(private_note) <= 280
  ),
  source public.entry_source not null default 'manual',
  idempotency_key text not null,
  -- Non-punitive audit metadata (never surfaced as an accusation).
  flagged_high_frequency boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  -- A custom serving must carry a volume.
  constraint custom_requires_volume check (serving_type <> 'custom' or volume_ml is not null)
);

comment on table public.pint_entries is 'One recorded drink. occurred_at is user time; created_at is server-authoritative.';

create unique index pint_entries_idempotency_idx on public.pint_entries (user_id, idempotency_key);
-- The workhorse index for period aggregates: only live rows, newest first, per user.
create index pint_entries_user_occurred_idx
  on public.pint_entries (user_id, occurred_at desc)
  where deleted_at is null;
create index pint_entries_session_idx
  on public.pint_entries (session_id)
  where session_id is not null and deleted_at is null;
create index pint_entries_pub_idx
  on public.pint_entries (user_id, pub_id)
  where pub_id is not null and deleted_at is null;

create trigger pint_entries_set_updated_at
  before update on public.pint_entries
  for each row execute function public.set_updated_at();

-- clinks --------------------------------------------------------------------------------
-- A decorative social memory. NEVER affects any drink total.
create table public.clinks (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.pub_sessions (id) on delete cascade,
  created_by uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now()
);

comment on table public.clinks is 'Decorative "we were here together" memory; does not change drink totals.';

create index clinks_session_idx on public.clinks (session_id);

create table public.clink_participants (
  clink_id uuid not null references public.clinks (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  confirmed_at timestamptz,
  primary key (clink_id, user_id)
);

create index clink_participants_user_idx on public.clink_participants (user_id);

-- user_pub_preferences ------------------------------------------------------------------
-- Explicit per-user overrides, e.g. hiding a particular pub from favourite-pub calcs.
create table public.user_pub_preferences (
  user_id uuid not null references public.profiles (id) on delete cascade,
  pub_id uuid not null references public.pubs (id) on delete cascade,
  hidden_from_favourites boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, pub_id)
);

comment on table public.user_pub_preferences is 'Optional per-user pub overrides (e.g. exclude from favourites).';

create trigger user_pub_preferences_set_updated_at
  before update on public.user_pub_preferences
  for each row execute function public.set_updated_at();
