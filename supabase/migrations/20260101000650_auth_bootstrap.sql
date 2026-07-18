-- CheekyPint schema — 06b. Auth bootstrap
--
-- Guarantee that every auth user has a profile + privacy row the instant they sign up, so
-- the rest of the app can assume they exist. Real display name/city/age-confirmation are
-- filled in during onboarding; this only seeds safe placeholders and the recommended
-- privacy defaults (which are the column defaults on privacy_settings).

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    coalesce(nullif(split_part(coalesce(new.email, ''), '@', 1), ''), 'New regular')
  )
  on conflict (id) do nothing;

  insert into public.privacy_settings (user_id)
  values (new.id)
  on conflict (user_id) do nothing;

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
