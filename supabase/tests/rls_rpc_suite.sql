-- RLS + RPC allow/deny suite. Runs under ON_ERROR_STOP=1: any FAIL raises and aborts.
-- We simulate the logged-in user with `set role authenticated` + `set app.uid = '<uuid>'`.


-- ============================ ALICE ============================
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000a1';

do $$ begin
  if (select count(*) from public.pint_entries) <> 4 then
    raise exception 'FAIL t1: Alice sees % entries (want 4)', (select count(*) from public.pint_entries); end if;
  raise notice 'PASS t1: Alice sees only her own 4 entries';
end $$;

do $$ begin
  if (select count(*) from public.pint_entries where user_id = '00000000-0000-4000-8000-0000000000b2') <> 0 then
    raise exception 'FAIL t2: Alice can see Barnaby raw entries'; end if;
  raise notice 'PASS t2: friend raw entries are invisible via direct select';
end $$;

do $$ begin
  if (select count(*) from public.get_friends()) <> 2 then
    raise exception 'FAIL t3: get_friends = % (want 2)', (select count(*) from public.get_friends()); end if;
  raise notice 'PASS t3: Alice has 2 friends; blocked Dev excluded';
end $$;

do $$ begin
  if (select count(*) from public.get_pending_requests()) <> 0 then
    raise exception 'FAIL t4: pending requests = % (want 0; Dev blocked)', (select count(*) from public.get_pending_requests()); end if;
  raise notice 'PASS t4: block removed Dev''s pending request';
end $$;

do $$
declare v_rows int; v_alice int; v_ceri_priv boolean; v_barnaby int;
begin
  select count(*) into v_rows from public.get_friend_leaderboard(now()-interval '7 days', now()+interval '1 minute','week',null);
  select recorded_count into v_alice from public.get_friend_leaderboard(now()-interval '7 days', now()+interval '1 minute','week',null) where is_current_user;
  select is_private into v_ceri_priv from public.get_friend_leaderboard(now()-interval '7 days', now()+interval '1 minute','week',null) where user_id = '00000000-0000-4000-8000-0000000000c3';
  select recorded_count into v_barnaby from public.get_friend_leaderboard(now()-interval '7 days', now()+interval '1 minute','week',null) where user_id = '00000000-0000-4000-8000-0000000000b2';
  if v_rows <> 3 then raise exception 'FAIL t5: leaderboard rows % (want 3)', v_rows; end if;
  if v_alice <> 3 then raise exception 'FAIL t5: Alice count % (want 3; AF excluded)', v_alice; end if;
  if not v_ceri_priv then raise exception 'FAIL t5: Ceri should be private'; end if;
  if v_barnaby <> 1 then raise exception 'FAIL t5: Barnaby count % (want 1)', v_barnaby; end if;
  raise notice 'PASS t5: leaderboard totals correct, alcohol-free excluded, private marker honoured';
end $$;

do $$ declare v jsonb; begin
  v := public.get_friend_profile('00000000-0000-4000-8000-0000000000b2');
  if v->>'display_name' <> 'Barnaby' then raise exception 'FAIL t8: name %', v; end if;
  if (v->>'city') is not null then raise exception 'FAIL t8: private city leaked %', v; end if;
  raise notice 'PASS t8: friend profile returns name but gates private city';
end $$;

do $$ declare ok boolean := false; begin
  begin
    insert into public.pint_entries (user_id, occurred_at, idempotency_key)
    values (auth.uid(), now(), 'direct-insert');
  exception when others then ok := true; end;
  if not ok then raise exception 'FAIL t13: direct pint insert was allowed'; end if;
  raise notice 'PASS t13: direct pint_entries insert blocked (no INSERT policy → RPC only)';
end $$;

do $$ declare n int; begin
  update public.profiles set display_name = 'Hacked' where id = '00000000-0000-4000-8000-0000000000b2';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL t14: updated % other profiles', n; end if;
  raise notice 'PASS t14: cannot update another user''s profile';
end $$;

do $$ declare n int; begin
  update public.profiles set bio = 'Loves a quiet pint' where id = '00000000-0000-4000-8000-0000000000a1';
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'FAIL t15: own update affected % rows', n; end if;
  raise notice 'PASS t15: can update own profile';
end $$;

do $$ declare cnt int; kings int; begin
  select count(*) into cnt from public.get_favourite_pubs('00000000-0000-4000-8000-0000000000a1');
  select visit_count into kings from public.get_favourite_pubs('00000000-0000-4000-8000-0000000000a1') where pub_id = '00000000-0000-4000-8000-00000000e001';
  if cnt <> 2 then raise exception 'FAIL t16: fav pubs % (want 2)', cnt; end if;
  if kings <> 2 then raise exception 'FAIL t16: Kings Arms visits % (want 2)', kings; end if;
  raise notice 'PASS t16: favourite pubs computed from own entries';
end $$;

do $$ declare ok boolean := false; begin
  perform public.send_nudge('00000000-0000-4000-8000-0000000000b2');
  begin
    perform public.send_nudge('00000000-0000-4000-8000-0000000000b2');
  exception when others then ok := true; end;
  if not ok then raise exception 'FAIL t21: stacked a second unanswered Nudge'; end if;
  raise notice 'PASS t21: one unanswered Nudge per friend is enforced';
end $$;

do $$ declare visible int; begin
  select count(*) into visible from public.nudges;
  if visible <> 0 then raise exception 'FAIL t22: direct Nudge table exposed % rows', visible; end if;
  raise notice 'PASS t22: direct Nudge rows are hidden; reads are RPC-only';
end $$;

-- ============================ BARNABY ============================
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000b2';

do $$ declare v jsonb; begin
  v := public.resolve_friend_token('seed-alice-token');
  if v->>'display_name' <> 'Alice' then raise exception 'FAIL t6: resolve %', v; end if;
  raise notice 'PASS t6: friend token resolves to safe preview (Alice)';
end $$;

do $$ declare a jsonb; b jsonb; cnt int; begin
  a := public.create_pint_entry('idem-x', now(), 'pint');
  b := public.create_pint_entry('idem-x', now(), 'pint');
  if (a->>'id') <> (b->>'id') then raise exception 'FAIL t10: idempotency produced two ids'; end if;
  select count(*) into cnt from public.pint_entries where user_id = auth.uid() and idempotency_key = 'idem-x';
  if cnt <> 1 then raise exception 'FAIL t10: % rows for idem-x', cnt; end if;
  raise notice 'PASS t10: create_pint_entry is idempotent';
end $$;

do $$ declare eid uuid; r jsonb; live int; begin
  select id into eid from public.pint_entries where user_id = auth.uid() and idempotency_key = 'idem-x';
  r := public.undo_recent_pint_entry(eid);
  if (r->>'deleted_at') is null then raise exception 'FAIL t12: entry not soft-deleted'; end if;
  select count(*) into live from public.pint_entries where idempotency_key = 'idem-x' and deleted_at is null;
  if live <> 0 then raise exception 'FAIL t12: entry still live after undo'; end if;
  raise notice 'PASS t12: undo soft-deletes the entry';
end $$;

do $$ declare ok boolean := false; begin
  begin perform public.get_favourite_pubs('00000000-0000-4000-8000-0000000000a1');
  exception when others then ok := true; end;
  if not ok then raise exception 'FAIL t17: saw Alice''s private favourite pubs'; end if;
  raise notice 'PASS t17: favourite pubs respect favourite_pubs_visibility';
end $$;

do $$ declare incoming int; remaining int; begin
  select count(*) into incoming from public.get_received_nudges()
    where sender_id = '00000000-0000-4000-8000-0000000000a1';
  if incoming <> 1 then raise exception 'FAIL t23: Barnaby received % Nudges from Alice', incoming; end if;
  perform public.send_nudge('00000000-0000-4000-8000-0000000000a1');
  select count(*) into remaining from public.get_received_nudges()
    where sender_id = '00000000-0000-4000-8000-0000000000a1';
  if remaining <> 0 then raise exception 'FAIL t23: Nudge back did not acknowledge incoming Nudge'; end if;
  raise notice 'PASS t23: Nudge back acknowledges incoming and returns a new Nudge';
end $$;

-- ============================ CERI ============================
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000c3';

do $$ declare ok boolean := false; begin
  begin perform public.create_pint_entry('ceri-sess', now(), 'pint', null, false, null,
                                          '00000000-0000-4000-8000-00000000f001');
  exception when others then ok := true; end;
  if not ok then raise exception 'FAIL t11: logged into a session Ceri never joined'; end if;
  raise notice 'PASS t11: create_pint_entry enforces session membership';
end $$;

-- ============================ DEV (blocked by Alice) ============================
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000d4';

do $$ declare ok boolean := false; begin
  begin perform public.resolve_friend_token('seed-alice-token');
  exception when others then ok := true; end;
  if not ok then raise exception 'FAIL t7: blocked Dev resolved Alice''s token'; end if;
  raise notice 'PASS t7: blocked user cannot resolve token';
end $$;

do $$ declare ok boolean := false; begin
  begin perform public.get_friend_profile('00000000-0000-4000-8000-0000000000a1');
  exception when others then ok := true; end;
  if not ok then raise exception 'FAIL t9: blocked Dev viewed Alice''s profile'; end if;
  raise notice 'PASS t9: blocked user cannot view profile';
end $$;

do $$ declare n int; begin
  select count(*) into n from public.get_friend_leaderboard(now()-interval '7 days', now()+interval '1 minute','week',null);
  if n <> 1 then raise exception 'FAIL t20: Dev leaderboard rows % (want 1: self only)', n; end if;
  raise notice 'PASS t20: friendless/blocked user sees only self on leaderboard';
end $$;

do $$ declare ok boolean := false; begin
  begin perform public.send_nudge('00000000-0000-4000-8000-0000000000a1');
  exception when others then ok := true; end;
  if not ok then raise exception 'FAIL t24: blocked user sent Alice a Nudge'; end if;
  raise notice 'PASS t24: blocked/non-friend user cannot send Nudge';
end $$;

-- ============================ TOKEN REVOCATION ============================
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000a1';
do $$ declare incoming int; begin
  select count(*) into incoming from public.get_received_nudges()
    where sender_id = '00000000-0000-4000-8000-0000000000b2';
  if incoming <> 1 then raise exception 'FAIL t25: Alice received % returned Nudges', incoming; end if;
  raise notice 'PASS t25: returned Nudge is visible to its recipient';
end $$;

do $$ declare t text; begin
  t := public.regenerate_friend_token();
  if t is null or length(t) < 20 then raise exception 'FAIL t18: bad token %', t; end if;
  raise notice 'PASS t18: regenerated friend token (length %)', length(t);
end $$;

reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000b2';
do $$ declare ok boolean := false; begin
  begin perform public.resolve_friend_token('seed-alice-token');
  exception when others then ok := true; end;
  if not ok then raise exception 'FAIL t19: revoked token still resolves'; end if;
  raise notice 'PASS t19: revoked token no longer resolves';
end $$;

-- ============================ FEED: table lockdown ============================
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000a1';

do $$ declare visible int; begin
  select count(*) into visible from public.posts;
  if visible <> 0 then raise exception 'FAIL t26: direct posts select exposed % rows', visible; end if;
  select count(*) into visible from public.post_cheers;
  if visible <> 0 then raise exception 'FAIL t26: direct post_cheers select exposed % rows', visible; end if;
  select count(*) into visible from public.post_comments;
  if visible <> 0 then raise exception 'FAIL t26: direct post_comments select exposed % rows', visible; end if;
  select count(*) into visible from public.comment_mentions;
  if visible <> 0 then raise exception 'FAIL t26: direct comment_mentions select exposed % rows', visible; end if;
  raise notice 'PASS t26: feed tables are invisible to direct selects';
end $$;

do $$ declare v text; begin
  select public.strip_ugc_control_chars('a' || chr(8203) || chr(9) || 'b' || chr(8237) || 'c') into v;
  if v <> 'abc' then raise exception 'FAIL t27: strip_ugc_control_chars gave %', v; end if;
  -- Bidi isolates and the word joiner are the Trojan-Source scrambling set.
  select public.strip_ugc_control_chars('d' || chr(8294) || chr(8295) || 'e' || chr(8296) || chr(8297) || chr(8288) || 'f') into v;
  if v <> 'def' then raise exception 'FAIL t27: bidi isolates/word joiner survived, got %', v; end if;
  -- C1 controls too.
  select public.strip_ugc_control_chars('g' || chr(133) || 'h') into v;
  if v <> 'gh' then raise exception 'FAIL t27: C1 control survived, got %', v; end if;
  raise notice 'PASS t27: control, zero-width, bidi and isolate characters are stripped';
end $$;

-- ============================ FEED: posts ============================
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000a1';

do $$ declare v jsonb; v_count int; begin
  select public.create_post('First pint of the trip', null, 'Prague', null) into v;
  if (v->>'post_id') is null then raise exception 'FAIL t28: create_post returned no post_id'; end if;
  select count(*) into v_count from public.feed_page(null, null, 20) where author_id = '00000000-0000-4000-8000-0000000000a1';
  if v_count <> 1 then raise exception 'FAIL t28: author sees % of own posts (want 1)', v_count; end if;
  raise notice 'PASS t28: create_post stores a post the author can read back';
end $$;

do $$ declare ok boolean; v_sqlstate text; begin
  ok := false;
  begin
    perform public.create_post(null, null, 'Prague', null);
  exception when others then
    ok := true; v_sqlstate := sqlstate;
  end;
  if not ok then raise exception 'FAIL t29: create_post accepted a post with neither body nor image'; end if;
  if v_sqlstate is distinct from '22023' then
    raise exception 'FAIL t29: wrong errcode % for empty post (want 22023)', v_sqlstate;
  end if;

  ok := false;
  begin
    perform public.create_post('x', null, null, '00000000-0000-4000-8000-00000000e001');
  exception when others then
    ok := true; v_sqlstate := sqlstate;
  end;
  if not ok then raise exception 'FAIL t29: create_post accepted a pub_id with no place_label'; end if;
  if v_sqlstate is distinct from '22023' then
    raise exception 'FAIL t29: wrong errcode % for unlabelled pub (want 22023)', v_sqlstate;
  end if;

  raise notice 'PASS t29: create_post rejects empty posts and unlabelled pub references with errcode 22023';
end $$;

do $$ declare v text; begin
  perform public.create_post('clean' || chr(8203) || chr(9) || 'text', null, null, null);
  select body into v from public.feed_page(null, null, 20) order by created_at desc limit 1;
  if v is distinct from 'cleantext' then raise exception 'FAIL t30: post body not sanitised, got %', v; end if;
  raise notice 'PASS t30: create_post strips control and zero-width characters from the body';
end $$;

-- Barnaby is an accepted friend of Alice; Ceri is a friend of Alice but NOT of Barnaby.
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000b2';
do $$ declare v_count int; begin
  select count(*) into v_count from public.feed_page(null, null, 20)
    where author_id = '00000000-0000-4000-8000-0000000000a1';
  if v_count <> 2 then raise exception 'FAIL t31: friend sees % of Alice posts (want 2)', v_count; end if;
  raise notice 'PASS t31: an accepted friend sees the posts';
end $$;

reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000d4';
do $$ declare v_count int; begin
  select count(*) into v_count from public.feed_page(null, null, 20);
  if v_count <> 0 then raise exception 'FAIL t31: blocked user sees % posts (want 0)', v_count; end if;
  raise notice 'PASS t31: a blocked user sees nothing';
end $$;

reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000a1';
do $$ declare v_id uuid; v_count int; begin
  select post_id into v_id from public.feed_page(null, null, 20) order by created_at desc limit 1;
  perform public.delete_post(v_id);
  select count(*) into v_count from public.feed_page(null, null, 20) where post_id = v_id;
  if v_count <> 0 then raise exception 'FAIL t32: soft-deleted post still visible'; end if;
  raise notice 'PASS t32: delete_post hides the post from every read path';
end $$;

reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000b2';
do $$ declare v_id uuid; ok boolean := false; begin
  select post_id into v_id from public.feed_page(null, null, 20) limit 1;
  if v_id is null then raise exception 'FAIL t32: no post to test with'; end if;
  begin
    perform public.delete_post(v_id);
  exception when others then ok := true;
  end;
  if not ok then raise exception 'FAIL t32: a non-author deleted someone else''s post'; end if;
  raise notice 'PASS t32: only the author can delete a post';
end $$;

-- ============================ FEED: friends-only, not just non-blocked ============================
-- Barnaby and Ceri are both Alice's friends but not each other's, and neither blocks the
-- other. If feed_page's visibility predicate were ever loosened from is_accepted_friend to a
-- bare not-blocked check ("total feed exposure"), every t26-t32 assertion above would still
-- pass unchanged — this is the gate that actually catches that regression.
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000b2';
do $$ declare v jsonb; begin
  select public.create_post('Barnaby-only post', null, null, null) into v;
  if (v->>'post_id') is null then raise exception 'FAIL t33: Barnaby could not create a post'; end if;
  raise notice 'PASS t33: Barnaby creates a post for the friends-only visibility check';
end $$;

reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000c3';
do $$ declare v_count int; begin
  select count(*) into v_count from public.feed_page(null, null, 20)
    where author_id = '00000000-0000-4000-8000-0000000000b2';
  if v_count <> 0 then raise exception 'FAIL t33: non-friend, non-blocked Ceri sees % of Barnaby posts (want 0)', v_count; end if;
  raise notice 'PASS t33: a non-friend who is not blocked still cannot see the posts';
end $$;

-- ============================ FEED: image path ownership ============================
-- The post-images bucket's own insert policy restricts uploads to the uploader's folder;
-- create_post must enforce the same rule, or a caller can pass a path they merely read
-- (unguessable filename, but readable once known) and re-broadcast someone else's photo.
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000b2';
do $$ declare ok boolean := false; v_sqlstate text; begin
  begin
    perform public.create_post('borrowed photo', '00000000-0000-4000-8000-0000000000a1/sneaky.jpg', null, null);
  exception when others then
    ok := true; v_sqlstate := sqlstate;
  end;
  if not ok then raise exception 'FAIL t34: create_post accepted an image path outside the caller''s folder'; end if;
  if v_sqlstate is distinct from '22023' then
    raise exception 'FAIL t34: wrong errcode % for foreign-folder image (want 22023)', v_sqlstate;
  end if;
  raise notice 'PASS t34: create_post rejects an image path outside the caller''s own folder';
end $$;

-- storage.foldername() drops the trailing filename segment (production semantics — see the
-- shim comment in _shim_bootstrap.sql). A path with no '/' at all therefore yields an EMPTY
-- array, so [1] is NULL; a bare "<> v_uid::text" comparison against NULL is itself NULL, which
-- skips the `if` and silently accepts. This is the gate for that NULL-unsafe class of bug.
do $$ declare ok boolean := false; v_sqlstate text; begin
  begin
    perform public.create_post('no folder at all', 'sneaky.jpg', null, null);
  exception when others then
    ok := true; v_sqlstate := sqlstate;
  end;
  if not ok then raise exception 'FAIL t34a: create_post accepted an image path with no folder segment'; end if;
  if v_sqlstate is distinct from '22023' then
    raise exception 'FAIL t34a: wrong errcode % for folderless image (want 22023)', v_sqlstate;
  end if;
  raise notice 'PASS t34a: create_post rejects an image path with no folder segment (NULL-safe ownership check)';
end $$;

-- The ownership check only inspects the FIRST folder segment; 'b2/../a1/x.jpg' leads with
-- Barnaby's own uid so that check alone would accept it, while most HTTP clients/CDNs
-- normalise the URL down to 'a1/x.jpg' before it reaches storage — reaching exactly the photo
-- the ownership check exists to block. A dedicated '..' rejection closes that gap.
do $$ declare ok boolean := false; v_sqlstate text; begin
  begin
    perform public.create_post('traversal attempt',
      '00000000-0000-4000-8000-0000000000b2/../00000000-0000-4000-8000-0000000000a1/x.jpg',
      null, null);
  exception when others then
    ok := true; v_sqlstate := sqlstate;
  end;
  if not ok then raise exception 'FAIL t34b: create_post accepted an image path containing a .. segment'; end if;
  if v_sqlstate is distinct from '22023' then
    raise exception 'FAIL t34b: wrong errcode % for path-traversal image (want 22023)', v_sqlstate;
  end if;
  raise notice 'PASS t34b: create_post rejects an image path containing a .. traversal segment';
end $$;

-- ============================ FEED: pagination cursor coverage ============================
-- No earlier test ever passed a non-null cursor into feed_page, so the compound-keyset logic
-- (I3/N2) had zero coverage. Ceri has created no posts yet, so her feed is a clean 3-row set.
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000c3';
do $$ declare v1 jsonb; v2 jsonb; v3 jsonb; begin
  select public.create_post('Ceri post 1', null, null, null) into v1;
  select public.create_post('Ceri post 2', null, null, null) into v2;
  select public.create_post('Ceri post 3', null, null, null) into v3;
  if (v1->>'post_id') is null or (v2->>'post_id') is null or (v3->>'post_id') is null then
    raise exception 'FAIL t34c: could not seed three posts for pagination coverage';
  end if;
  raise notice 'PASS t34c: seeded three posts for pagination coverage';
end $$;

do $$
declare
  v_page1_ids uuid[];
  v_cursor_created timestamptz;
  v_cursor_id uuid;
  v_page2_ids uuid[];
begin
  select array_agg(post_id order by created_at desc, post_id desc) into v_page1_ids
    from public.feed_page(null, null, 2)
   where author_id = '00000000-0000-4000-8000-0000000000c3';
  if coalesce(array_length(v_page1_ids, 1), 0) <> 2 then
    raise exception 'FAIL t34c: page 1 returned % rows (want 2)', coalesce(array_length(v_page1_ids, 1), 0);
  end if;

  -- The cursor is the LAST row shown on page 1 (in display order) — i.e. the older of the two.
  select created_at, post_id into v_cursor_created, v_cursor_id
    from public.feed_page(null, null, 2)
   where author_id = '00000000-0000-4000-8000-0000000000c3'
   order by created_at asc, post_id asc
   limit 1;

  select array_agg(post_id order by created_at desc, post_id desc) into v_page2_ids
    from public.feed_page(v_cursor_created, v_cursor_id, 20)
   where author_id = '00000000-0000-4000-8000-0000000000c3';

  if coalesce(array_length(v_page2_ids, 1), 0) <> 1 then
    raise exception 'FAIL t34c: page 2 returned % rows (want 1)', coalesce(array_length(v_page2_ids, 1), 0);
  end if;
  if v_page2_ids[1] = any(v_page1_ids) then
    raise exception 'FAIL t34c: page 2 repeated a page 1 row';
  end if;

  raise notice 'PASS t34c: keyset cursor advances to page 2 without repeating page 1''s rows';
end $$;

-- ============================ FEED: cheers, comments, mentions ============================
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000a1';

do $$ declare v_post uuid; v jsonb; begin
  -- Filter by author: Task 3's t34c seeded Ceri-owned posts, so an unfiltered limit 1 is
  -- no longer deterministic under Alice's identity.
  select post_id into v_post from public.feed_page(null, null, 20)
    where author_id = '00000000-0000-4000-8000-0000000000a1' limit 1;
  if v_post is null then raise exception 'FAIL: no Alice post available'; end if;
  select public.toggle_post_cheers(v_post) into v;
  if (v->>'cheered')::boolean is not true then raise exception 'FAIL t35: first toggle did not cheer'; end if;
  if (v->>'cheers_count')::int is distinct from 1 then raise exception 'FAIL t35: count % (want 1)', v->>'cheers_count'; end if;
  select public.toggle_post_cheers(v_post) into v;
  if (v->>'cheered')::boolean is not false then raise exception 'FAIL t35: second toggle did not un-cheer'; end if;
  if (v->>'cheers_count')::int is distinct from 0 then raise exception 'FAIL t35: count % (want 0)', v->>'cheers_count'; end if;
  raise notice 'PASS t35: toggle_post_cheers is idempotent per user and counts correctly';
end $$;

do $$ declare v_post uuid; v jsonb; v_body text; v_mentions uuid[]; begin
  -- Filter by author: Task 3's t34c seeded Ceri-owned posts, so an unfiltered limit 1 is
  -- no longer deterministic under Alice's identity.
  select post_id into v_post from public.feed_page(null, null, 20)
    where author_id = '00000000-0000-4000-8000-0000000000a1' limit 1;
  if v_post is null then raise exception 'FAIL: no Alice post available'; end if;
  select public.add_comment(v_post, 'nice one' || chr(8203) || '!',
                            array['00000000-0000-4000-8000-0000000000b2'::uuid]) into v;
  if (v->>'comment_id') is null then raise exception 'FAIL t36: add_comment returned no id'; end if;
  select body, mentioned_user_ids into v_body, v_mentions
    from public.post_comments_page(v_post, null, null, 20) limit 1;
  if v_body is distinct from 'nice one!' then raise exception 'FAIL t36: comment body not sanitised, got %', v_body; end if;
  if v_mentions is distinct from array['00000000-0000-4000-8000-0000000000b2'::uuid] then
    raise exception 'FAIL t36: mentions % wrong', v_mentions; end if;
  raise notice 'PASS t36: add_comment sanitises the body and records mentions';
end $$;

-- C1 regression: post_comments_page's avatar gate is about the VIEWER's relationship to the
-- COMMENTER, not to the post author. Barnaby comments on Alice's post (visible to him as her
-- friend); Ceri can also see the thread (she is Alice's friend too) but is a stranger to
-- Barnaby, so she must not receive his avatar even though avatar_visibility defaults to
-- 'friends'. Alice, who IS Barnaby's friend, must still receive it — proving the fix does not
-- just blank the field for everyone.
do $$ declare v_post uuid; v_avatar_ceri text; v_avatar_alice text; begin
  select post_id into v_post from public.feed_page(null, null, 20)
    where author_id = '00000000-0000-4000-8000-0000000000a1' limit 1;
  if v_post is null then raise exception 'FAIL t36a: no Alice post available'; end if;

  perform set_config('app.uid', '00000000-0000-4000-8000-0000000000b2', false);
  update public.profiles set avatar_path = 'b2/barnaby.jpg' where id = auth.uid();
  perform public.add_comment(v_post, 'hi from Barnaby', null);

  perform set_config('app.uid', '00000000-0000-4000-8000-0000000000c3', false);
  select avatar_path into v_avatar_ceri from public.post_comments_page(v_post, null, null, 20)
    where author_id = '00000000-0000-4000-8000-0000000000b2';
  if v_avatar_ceri is not null then
    raise exception 'FAIL t36a: Ceri (a stranger to Barnaby) received Barnaby''s avatar_path %', v_avatar_ceri;
  end if;

  perform set_config('app.uid', '00000000-0000-4000-8000-0000000000a1', false);
  select avatar_path into v_avatar_alice from public.post_comments_page(v_post, null, null, 20)
    where author_id = '00000000-0000-4000-8000-0000000000b2';
  if v_avatar_alice is distinct from 'b2/barnaby.jpg' then
    raise exception 'FAIL t36a: Alice (Barnaby''s friend) did not receive his avatar_path, got %', v_avatar_alice;
  end if;

  raise notice 'PASS t36a: comment avatar_path is gated on the VIEWER being a friend of the commenter';
end $$;

-- Dev is blocked by Alice, so he is not a mentionable friend.
do $$ declare v_post uuid; ok boolean := false; begin
  -- Filter by author: Task 3's t34c seeded Ceri-owned posts, so an unfiltered limit 1 is
  -- no longer deterministic under Alice's identity.
  select post_id into v_post from public.feed_page(null, null, 20)
    where author_id = '00000000-0000-4000-8000-0000000000a1' limit 1;
  if v_post is null then raise exception 'FAIL: no Alice post available'; end if;
  if v_post is null then raise exception 'FAIL t37: no post to comment on'; end if;
  begin
    perform public.add_comment(v_post, 'hi', array['00000000-0000-4000-8000-0000000000d4'::uuid]);
  exception when others then ok := true;
  end;
  if not ok then raise exception 'FAIL t37: mentioned a non-friend'; end if;
  raise notice 'PASS t37: mentioning a non-friend is rejected';
end $$;

-- Barnaby's identity for the remaining feed-social tests below: he creates his own post, and is
-- the friend recruited to isolate the mention checks from Alice's own social graph.
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000b2';

-- I4 regression: a mention target must ALSO be able to see the post, not merely be a friend of
-- the commenter. t37 alone cannot prove this half of the check, because Dev fails BOTH the
-- friendship test and the visibility test there. Make Barnaby and Dev friends first, so the
-- ONLY thing left that can reject this comment is Dev's inability to see ALICE's post (she
-- blocked him) — isolating the can_view_post half of the mention check from the
-- is_accepted_friend half.
do $$ declare v_post uuid; v_req jsonb; ok boolean := false; begin
  select public.send_friend_request('00000000-0000-4000-8000-0000000000d4') into v_req;

  perform set_config('app.uid', '00000000-0000-4000-8000-0000000000d4', false);
  perform public.respond_to_friend_request((v_req->>'friendship_id')::uuid, true);
  perform set_config('app.uid', '00000000-0000-4000-8000-0000000000b2', false);

  select post_id into v_post from public.feed_page(null, null, 20)
    where author_id = '00000000-0000-4000-8000-0000000000a1' limit 1;
  if v_post is null then raise exception 'FAIL t37b: no Alice post available'; end if;

  begin
    perform public.add_comment(v_post, 'hi', array['00000000-0000-4000-8000-0000000000d4'::uuid]);
  exception when others then ok := true;
  end;
  if not ok then
    raise exception 'FAIL t37b: mentioned a friend who cannot see the post (blocked by its author)';
  end if;
  raise notice 'PASS t37b: mention target must also be able to view the post, not merely be a friend of the commenter';
end $$;

-- I7 regression: pin the friends-only mention rule in isolation from post VISIBILITY. This
-- deliberately uses ALICE's post, not Barnaby's own: Ceri is Alice's accepted friend
-- (seed.sql:59-61), so can_view_post(Ceri, alice_post) is TRUE — that half of add_comment's
-- `not is_accepted_friend(...) or not can_view_post(...)` guard cannot mask anything here.
-- Ceri is not Barnaby's friend, and nobody has blocked anybody in this pair, so a rejection can
-- ONLY be explained by is_accepted_friend(Barnaby, Ceri) being false. (An earlier version of
-- this test used Barnaby's own post as the target; there, Ceri could not view that post EITHER,
-- so the can_view_post half of the guard alone would reject the mention even if the friendship
-- half were regressed to a bare "not is_blocked" check — the exact I7 regression this test
-- exists to catch would have gone undetected.)
do $$ declare v_post uuid; ok boolean := false; begin
  select post_id into v_post from public.feed_page(null, null, 20)
    where author_id = '00000000-0000-4000-8000-0000000000a1' limit 1;
  if v_post is null then raise exception 'FAIL t37c: no Alice post available'; end if;

  begin
    perform public.add_comment(v_post, 'hey', array['00000000-0000-4000-8000-0000000000c3'::uuid]);
  exception when others then ok := true;
  end;
  if not ok then
    raise exception 'FAIL t37c: mentioning a non-friend who CAN see the post was accepted';
  end if;
  raise notice 'PASS t37c: mentioning a non-friend who can see the post is still rejected on friendship grounds alone';
end $$;

-- Ceri is Alice's friend but not Barnaby's, so Ceri must not reach Barnaby's post.
do $$ declare v jsonb; v_post uuid; ok_cheer boolean := false; ok_comment boolean := false; begin
  select public.create_post('Barnaby was here', null, null, null) into v;
  v_post := (v->>'post_id')::uuid;

  -- Ceri is Alice's friend but not Barnaby's, and nobody has blocked anybody here: this is the
  -- non-friend, non-blocked case that distinguishes friends-only from merely not-blocked.
  perform set_config('app.uid', '00000000-0000-4000-8000-0000000000c3', false);
  begin
    perform public.toggle_post_cheers(v_post);
  exception when others then ok_cheer := true;
  end;
  begin
    perform public.add_comment(v_post, 'sneaking in', null);
  exception when others then ok_comment := true;
  end;
  if not ok_cheer then raise exception 'FAIL t38: a non-friend cheered a post they cannot see'; end if;
  if not ok_comment then raise exception 'FAIL t38: a non-friend commented on a post they cannot see'; end if;
  raise notice 'PASS t38: cheers and comments require visibility of the post';
end $$;

-- I6 regression: post_comments_page's own can_view_post guard had no test — removing it from
-- the query left the whole suite green while any authenticated caller holding a post id could
-- read an entire friends-only thread. Ceri is Alice's friend but not Barnaby's, and nobody is
-- blocked here, so this pins the friends-only read guard specifically (not a block check).
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000b2';
do $$ declare v_post uuid; v jsonb; v_count int; begin
  select public.create_post('Barnaby thread for the read-guard check', null, null, null) into v;
  v_post := (v->>'post_id')::uuid;

  -- Ensure the thread is non-empty, so a zero-row result below can only be explained by the
  -- visibility guard, not by there being nothing to read.
  perform public.add_comment(v_post, 'a comment that exists', null);

  perform set_config('app.uid', '00000000-0000-4000-8000-0000000000c3', false);
  select count(*) into v_count from public.post_comments_page(v_post, null, null, 20);
  if v_count <> 0 then
    raise exception 'FAIL t40: a non-friend read % comments on a post they cannot see', v_count;
  end if;
  raise notice 'PASS t40: post_comments_page hides comments from non-friends of the post''s author';
end $$;

reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000a1';
do $$ declare v_post uuid; v_comment uuid; v_count int; begin
  select post_id into v_post from public.feed_page(null, null, 20)
    where author_id = '00000000-0000-4000-8000-0000000000a1' limit 1;
  -- Filter by author: several other identities have now also commented on this post (t36a,
  -- t37b), so an unfiltered limit 1 is not guaranteed to be a comment Alice herself owns, and
  -- delete_comment's ownership guard would then correctly reject Alice's own delete attempt.
  select comment_id into v_comment from public.post_comments_page(v_post, null, null, 20)
    where author_id = '00000000-0000-4000-8000-0000000000a1' limit 1;
  perform public.delete_comment(v_comment);
  select count(*) into v_count from public.post_comments_page(v_post, null, null, 20) where comment_id = v_comment;
  if v_count <> 0 then raise exception 'FAIL t38: soft-deleted comment still visible'; end if;
  raise notice 'PASS t38: delete_comment hides the comment';
end $$;

-- I5 regression: delete_comment's ownership guard (author_id = v_uid) previously had no test —
-- removing that clause left the whole suite green. Barnaby is a friend who can see this comment
-- but did not write it, so he must not be able to delete it, and it must still be there after.
do $$ declare v_post uuid; v_comment uuid; v jsonb; ok boolean := false; v_count int; begin
  select post_id into v_post from public.feed_page(null, null, 20)
    where author_id = '00000000-0000-4000-8000-0000000000a1' limit 1;
  select public.add_comment(v_post, 'do not delete me', null) into v;
  v_comment := (v->>'comment_id')::uuid;

  perform set_config('app.uid', '00000000-0000-4000-8000-0000000000b2', false);
  begin
    perform public.delete_comment(v_comment);
  exception when others then ok := true;
  end;
  if not ok then raise exception 'FAIL t39: a non-author deleted someone else''s comment'; end if;

  perform set_config('app.uid', '00000000-0000-4000-8000-0000000000a1', false);
  select count(*) into v_count from public.post_comments_page(v_post, null, null, 20)
    where comment_id = v_comment;
  if v_count <> 1 then raise exception 'FAIL t39: comment wrongly removed after rejected delete attempt'; end if;

  raise notice 'PASS t39: only the comment''s author can delete it';
end $$;

-- ============================ FEED: reporting ============================
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000a1';

do $$ declare v_post uuid; v jsonb; v_reported uuid; v_linked uuid; begin
  select post_id into v_post from public.feed_page(null, null, 20)
    where author_id = '00000000-0000-4000-8000-0000000000b2' limit 1;
  if v_post is null then raise exception 'FAIL t41: no Barnaby post to report'; end if;
  select public.report_post(v_post, 'inappropriate_post_image', 'not on') into v;
  if (v->>'report_id') is null then raise exception 'FAIL t41: report_post returned no id'; end if;
  if (v->>'status') <> 'open' then raise exception 'FAIL t41: status % (want open)', v->>'status'; end if;
  select reported_user_id, post_id into v_reported, v_linked
    from public.reports where id = (v->>'report_id')::uuid;
  if v_reported <> '00000000-0000-4000-8000-0000000000b2' then
    raise exception 'FAIL t41: reported_user_id % is not the post author', v_reported; end if;
  if v_linked <> v_post then raise exception 'FAIL t41: report not linked to the post'; end if;
  raise notice 'PASS t41: report_post files against the author and links the post';
end $$;

do $$ declare v_own uuid; ok_self boolean := false; ok_hidden boolean := false; begin
  select post_id into v_own from public.feed_page(null, null, 20)
    where author_id = '00000000-0000-4000-8000-0000000000a1' limit 1;
  if v_own is null then raise exception 'FAIL t42: no own post to test with'; end if;
  begin
    perform public.report_post(v_own, 'inappropriate_text', null);
  exception when others then ok_self := true;
  end;
  begin
    perform public.report_post('00000000-0000-4000-8000-00000000dead', 'inappropriate_text', null);
  exception when others then ok_hidden := true;
  end;
  if not ok_self then raise exception 'FAIL t42: reported own post'; end if;
  if not ok_hidden then raise exception 'FAIL t42: reported an invisible post'; end if;
  raise notice 'PASS t42: cannot report your own post or one you cannot see';
end $$;

reset role;
\echo '-------------------------------------------'
\echo 'ALL RLS/RPC CHECKS PASSED'
\echo '-------------------------------------------'
