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
