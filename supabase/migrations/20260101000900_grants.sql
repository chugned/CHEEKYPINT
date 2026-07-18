-- CheekyPint schema — 09. Function execution grants
--
-- Default to least privilege: anon can call nothing; authenticated can call the client RPCs
-- and the RLS predicate helpers, but NOT the internal-only functions.

revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;

-- Internal-only functions: triggers and rate-limit plumbing must not be callable directly.
revoke execute on function public.enforce_rate_limit(text, int, interval) from authenticated;
revoke execute on function public.prune_rate_limit_events(interval) from authenticated;
revoke execute on function public.handle_new_user() from authenticated;
revoke execute on function public.set_updated_at() from authenticated;

-- Make future functions follow the same default (Supabase applies this too, but be explicit).
alter default privileges in schema public revoke execute on functions from public, anon;
