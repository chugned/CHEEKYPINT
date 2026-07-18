-- CheekyPint schema — 01. Extensions & enum types
--
-- All application tables live in `public`. Cryptographic helpers (digest) come from
-- pgcrypto; case-insensitive usernames use citext. Enum types keep status/visibility
-- columns constrained at the database level rather than relying on app validation alone.

create extension if not exists pgcrypto with schema extensions;
create extension if not exists citext with schema extensions;

-- Field visibility. Deliberately NO 'public' value in the MVP: the most a value is ever
-- shared is with accepted friends.
create type public.visibility as enum ('private', 'friends');

create type public.friendship_status as enum ('pending', 'accepted', 'declined', 'removed');

create type public.session_status as enum ('active', 'ended');

create type public.session_member_role as enum ('host', 'member');

create type public.pub_source as enum ('mapkit', 'user_suggested');

create type public.entry_source as enum ('manual', 'quick_log', 'offline_queue');

-- Physical serving size. Alcohol-free is a separate boolean flag, not a size.
create type public.serving_type as enum ('half_pint', 'pint', 'ml_330', 'ml_500', 'custom');

create type public.report_category as enum (
  'inappropriate_profile_image',
  'inappropriate_text',
  'harassment',
  'impersonation',
  'underage_concern',
  'other'
);

create type public.report_status as enum ('open', 'reviewing', 'actioned', 'dismissed');
