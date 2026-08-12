-- CheekyPint schema — 01b. Common functions
--
-- Shared trigger + tiny helpers used across later migrations. Kept SECURITY INVOKER and
-- with a locked search_path.

-- Touch `updated_at` on every UPDATE.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

comment on function public.set_updated_at is
  'Trigger function that stamps updated_at = now() on row updates.';

-- Shared sanitiser for user-supplied text. Deletes C0/C1 control characters plus the
-- zero-width and bidi-override characters used to spoof or scramble displayed text.
--
-- Lives here, not with the feed tables that first needed it, because it is also called by
-- public.report_user (20260101000800_rpc_social.sql) — every RPC that writes free text a human
-- later reads goes through it, and those RPCs are spread across migrations from 000800 onwards.
-- A helper referenced by an earlier migration than the one defining it only works by accident
-- (plpgsql bodies are not name-resolved at CREATE time); declaring it up front makes the
-- dependency real.
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
             chr(8234) || chr(8235) || chr(8236) || chr(8237) || chr(8238) || chr(65279) ||
             chr(8288) || chr(8294) || chr(8295) || chr(8296) || chr(8297),
             ''
           ),
           '[[:cntrl:]]', '', 'g'
         );
$$;

comment on function public.strip_ugc_control_chars(text) is
  'Strips control, zero-width and bidi characters from user-supplied text.';

revoke all on function public.strip_ugc_control_chars(text) from public, anon;
grant execute on function public.strip_ugc_control_chars(text) to authenticated;
