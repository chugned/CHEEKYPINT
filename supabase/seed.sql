-- CheekyPint seed data — deterministic fixtures for local development and manual testing.
-- Applied by `supabase db reset`. Inserting into auth.users fires handle_new_user(), which
-- creates the matching profiles + privacy_settings rows; we then enrich them.
--
-- Fixed UUIDs so tests and the app can reference known rows.
--   Alice   00000000-0000-4000-8000-0000000000a1  (hub user)
--   Barnaby 00000000-0000-4000-8000-0000000000b2  (Alice's friend)
--   Ceri    00000000-0000-4000-8000-0000000000c3  (Alice's friend; hides weekly total)
--   Dev     00000000-0000-4000-8000-0000000000d4  (blocked by Alice)

-- 1. Auth users (email + password so they can sign in locally). ---------------------------
insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
                        email_confirmed_at, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
values
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-4000-8000-0000000000a1',
   'authenticated', 'authenticated', 'alice@cheekypint.test',
   extensions.crypt('password123', extensions.gen_salt('bf')), now(), now(), now(),
   '{"provider":"email","providers":["email"]}', '{}'),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-4000-8000-0000000000b2',
   'authenticated', 'authenticated', 'barnaby@cheekypint.test',
   extensions.crypt('password123', extensions.gen_salt('bf')), now(), now(), now(),
   '{"provider":"email","providers":["email"]}', '{}'),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-4000-8000-0000000000c3',
   'authenticated', 'authenticated', 'ceri@cheekypint.test',
   extensions.crypt('password123', extensions.gen_salt('bf')), now(), now(), now(),
   '{"provider":"email","providers":["email"]}', '{}'),
  ('00000000-0000-0000-0000-000000000000', '00000000-0000-4000-8000-0000000000d4',
   'authenticated', 'authenticated', 'dev@cheekypint.test',
   extensions.crypt('password123', extensions.gen_salt('bf')), now(), now(), now(),
   '{"provider":"email","providers":["email"]}', '{}')
on conflict (id) do nothing;

-- 2. Enrich profiles (broad city only, legal age confirmed). ------------------------------
update public.profiles set display_name = 'Alice',  username = 'alice',  city = 'Graz, Austria',
  country_code = 'AT', timezone = 'Europe/Vienna', locale = 'en_GB', legal_age_confirmed_at = now()
  where id = '00000000-0000-4000-8000-0000000000a1';
update public.profiles set display_name = 'Barnaby', username = 'barnaby', city = 'London, UK',
  country_code = 'GB', timezone = 'Europe/London', locale = 'en_GB', legal_age_confirmed_at = now()
  where id = '00000000-0000-4000-8000-0000000000b2';
update public.profiles set display_name = 'Ceri', username = 'ceri', city = 'Cardiff, UK',
  country_code = 'GB', timezone = 'Europe/London', locale = 'en_GB', legal_age_confirmed_at = now()
  where id = '00000000-0000-4000-8000-0000000000c3';
update public.profiles set display_name = 'Dev', username = 'dev',
  timezone = 'Europe/Vienna', locale = 'en_GB', legal_age_confirmed_at = now()
  where id = '00000000-0000-4000-8000-0000000000d4';

-- Ceri hides her weekly total → she should appear as "Private" on the weekly leaderboard.
update public.privacy_settings set weekly_total_visibility = 'private'
  where user_id = '00000000-0000-4000-8000-0000000000c3';

-- 3. A known friend token for Alice, so resolve_friend_token('seed-alice-token') works. ----
insert into public.friend_tokens (user_id, token_hash)
values ('00000000-0000-4000-8000-0000000000a1',
        encode(extensions.digest('seed-alice-token', 'sha256'), 'hex'))
on conflict (token_hash) do nothing;

-- 4. Friendships: Alice–Barnaby accepted, Alice–Ceri accepted, Dev→Alice pending. ----------
insert into public.friendships (requester_id, addressee_id, status, responded_at) values
  ('00000000-0000-4000-8000-0000000000a1', '00000000-0000-4000-8000-0000000000b2', 'accepted', now()),
  ('00000000-0000-4000-8000-0000000000c3', '00000000-0000-4000-8000-0000000000a1', 'accepted', now())
on conflict do nothing;

-- Dev sends Alice a request, then Alice blocks Dev — the block must override the request.
insert into public.friendships (requester_id, addressee_id, status)
values ('00000000-0000-4000-8000-0000000000d4', '00000000-0000-4000-8000-0000000000a1', 'pending')
on conflict do nothing;
insert into public.blocks (blocker_id, blocked_id)
values ('00000000-0000-4000-8000-0000000000a1', '00000000-0000-4000-8000-0000000000d4')
on conflict do nothing;
update public.friendships set status = 'removed'
  where requester_id = '00000000-0000-4000-8000-0000000000d4'
    and addressee_id = '00000000-0000-4000-8000-0000000000a1';

-- 5. Pubs. -------------------------------------------------------------------------------
insert into public.pubs (id, external_source, external_identifier, name, formatted_address, city, country_code, latitude, longitude, created_by) values
  ('00000000-0000-4000-8000-00000000e001', 'user_suggested', null, 'The Kings Arms', '25 Roupell St, London', 'London', 'GB', 51.5045, -0.1105, '00000000-0000-4000-8000-0000000000a1'),
  ('00000000-0000-4000-8000-00000000e002', 'user_suggested', null, 'Zum Goldenen Krug', 'Hauptplatz 1, Graz', 'Graz', 'AT', 47.0707, 15.4395, '00000000-0000-4000-8000-0000000000a1')
on conflict do nothing;

-- 6. An active session hosted by Alice at The Kings Arms; Barnaby joined. -----------------
insert into public.pub_sessions (id, pub_id, host_user_id, name, status, started_at, join_token_hash)
values ('00000000-0000-4000-8000-00000000f001', '00000000-0000-4000-8000-00000000e001',
        '00000000-0000-4000-8000-0000000000a1', 'Friday at the Kings', 'active', now() - interval '1 hour',
        encode(extensions.digest('seed-session-token', 'sha256'), 'hex'))
on conflict do nothing;

insert into public.session_members (session_id, user_id, role) values
  ('00000000-0000-4000-8000-00000000f001', '00000000-0000-4000-8000-0000000000a1', 'host'),
  ('00000000-0000-4000-8000-00000000f001', '00000000-0000-4000-8000-0000000000b2', 'member')
on conflict do nothing;

-- 7. Pint entries. Alice: 2 in this session + a couple earlier; Barnaby: 1 in session;
--    Ceri: 3 this week (but she hides the weekly total). -----------------------------------
insert into public.pint_entries (user_id, pub_id, session_id, occurred_at, serving_type, alcohol_free, idempotency_key) values
  ('00000000-0000-4000-8000-0000000000a1', '00000000-0000-4000-8000-00000000e001', '00000000-0000-4000-8000-00000000f001', now() - interval '50 minutes', 'pint', false, 'seed-a-1'),
  ('00000000-0000-4000-8000-0000000000a1', '00000000-0000-4000-8000-00000000e001', '00000000-0000-4000-8000-00000000f001', now() - interval '20 minutes', 'pint', false, 'seed-a-2'),
  ('00000000-0000-4000-8000-0000000000a1', '00000000-0000-4000-8000-00000000e002', null, now() - interval '3 days', 'half_pint', false, 'seed-a-3'),
  ('00000000-0000-4000-8000-0000000000a1', null, null, now() - interval '10 minutes', 'ml_330', true, 'seed-a-af'),
  ('00000000-0000-4000-8000-0000000000b2', '00000000-0000-4000-8000-00000000e001', '00000000-0000-4000-8000-00000000f001', now() - interval '30 minutes', 'pint', false, 'seed-b-1'),
  ('00000000-0000-4000-8000-0000000000c3', null, null, now() - interval '2 days', 'pint', false, 'seed-c-1'),
  ('00000000-0000-4000-8000-0000000000c3', null, null, now() - interval '1 day', 'pint', false, 'seed-c-2'),
  ('00000000-0000-4000-8000-0000000000c3', null, null, now() - interval '4 hours', 'pint', false, 'seed-c-3')
on conflict do nothing;
