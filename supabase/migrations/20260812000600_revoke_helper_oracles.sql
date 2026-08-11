-- CheekyPint: relationship helpers must not be client-callable.
--
-- 20260101000900_grants.sql runs `grant execute on all functions in schema public to
-- authenticated` after 20260101000600_security_helpers.sql created these, and unlike can_view_post
-- they were never individually revoked. That left any authenticated user able to ask
-- `is_accepted_friend(<a>, <b>)` about arbitrary people — a direct read of someone else's social
-- graph — and `is_blocked(<a>, <b>)`, which discloses that a specific pair blocked each other.
--
-- Safe to revoke: no RLS policy calls these. The only policy-side use is inside
-- public.can_read_post_image (20260812000100_private_post_images.sql), which is security definer
-- and runs as the owner, as do every RPC and helper that composes them (e.g. feed_page,
-- add_comment, get_friend_leaderboard). Those nested calls are unaffected by this revoke: a
-- SECURITY DEFINER function executes with the privileges of its owner, not of the calling
-- `authenticated` role, so it never needs EXECUTE granted to `authenticated` in order to invoke
-- another function it composes internally.
--
-- enforce_rate_limit and prune_rate_limit_events are not touched here — they were already
-- revoked from authenticated in 20260101000600_security_helpers.sql (and again, redundantly, in
-- 20260101000900_grants.sql), and neither is a relationship oracle.
revoke execute on function public.is_accepted_friend(uuid, uuid) from authenticated;
revoke execute on function public.is_blocked(uuid, uuid) from authenticated;
revoke execute on function public.can_view_profile(uuid, uuid) from authenticated;
revoke execute on function public.shares_active_session(uuid, uuid) from authenticated;
