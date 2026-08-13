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

-- t27b: the newline-preserving sibling, asserted directly rather than only through its callers.
-- Every case below is a separate literal expectation, so no single mistake in the function can pass
-- all of them: the first pins that the OTHER control characters still go while LF survives, the
-- next two pin CRLF/CR normalisation, the fourth blank-line collapsing, the fifth end-trimming, and
-- the last two the degenerate inputs the callers' nullif(..., '') depends on.
do $$ declare v text; begin
  -- LF survives; the tab, zero-width space and RTL override on either side of it do not.
  select public.strip_ugc_control_chars_multiline(
           'a' || chr(9) || chr(8203) || chr(10) || chr(8237) || 'b') into v;
  if v is distinct from 'a' || chr(10) || 'b' then
    raise exception 'FAIL t27b: expected a<LF>b, got %', quote_literal(v); end if;

  -- CRLF is one break, not two and not zero.
  select public.strip_ugc_control_chars_multiline('a' || chr(13) || chr(10) || 'b') into v;
  if v is distinct from 'a' || chr(10) || 'b' then
    raise exception 'FAIL t27b: CRLF became %', quote_literal(v); end if;

  -- A lone CR (some on-screen keyboards) is a break too, not a deletion.
  select public.strip_ugc_control_chars_multiline('a' || chr(13) || 'b') into v;
  if v is distinct from 'a' || chr(10) || 'b' then
    raise exception 'FAIL t27b: lone CR became %', quote_literal(v); end if;

  -- One blank line survives (an ordinary paragraph break); a run of them collapses to one.
  select public.strip_ugc_control_chars_multiline('a' || repeat(chr(10), 2) || 'b') into v;
  if v is distinct from 'a' || repeat(chr(10), 2) || 'b' then
    raise exception 'FAIL t27b: a single blank line must survive, got %', quote_literal(v); end if;
  select public.strip_ugc_control_chars_multiline('a' || repeat(chr(10), 40) || 'b') into v;
  if v is distinct from 'a' || repeat(chr(10), 2) || 'b' then
    raise exception 'FAIL t27b: 40 newlines collapsed to %', quote_literal(v); end if;

  -- Ends are trimmed, including newlines (btrim alone would leave the blank lines).
  select public.strip_ugc_control_chars_multiline(chr(10) || '  a' || chr(10) || 'b  ' || chr(10)) into v;
  if v is distinct from 'a' || chr(10) || 'b' then
    raise exception 'FAIL t27b: ends not trimmed, got %', quote_literal(v); end if;

  -- Degenerate inputs the callers' nullif(..., '') relies on.
  select public.strip_ugc_control_chars_multiline(repeat(chr(10), 5)) into v;
  if v is distinct from '' then
    raise exception 'FAIL t27b: newlines-only gave %, want empty', quote_literal(v); end if;
  select public.strip_ugc_control_chars_multiline(null) into v;
  if v is distinct from '' then
    raise exception 'FAIL t27b: null gave %, want empty', quote_literal(v); end if;

  raise notice 'PASS t27b: strip_ugc_control_chars_multiline keeps line breaks, normalises CRLF/CR, collapses blank-line runs and trims its ends';
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

-- I2 regression: a mention target who IS the commenter's accepted friend but who cannot
-- independently see the post (here, because the post's author has blocked them) must be
-- SILENTLY DROPPED from the mention list, not rejected. Raising here would be a friend-graph
-- oracle: Barnaby already knows Dev is his friend, so a rejection distinguishable from "not your
-- friend" could only be explained by some hidden relationship between Dev and Alice (the post's
-- author) that Barnaby has no way to see directly — e.g. that Alice blocked Dev. Make Barnaby and
-- Dev friends first, so the ONLY thing that could otherwise reject this comment is Dev's
-- inability to see ALICE's post, isolating the can_view_post half of the mention check from the
-- is_accepted_friend half.
do $$ declare v_post uuid; v_req jsonb; v jsonb; v_comment_id uuid; v_mentions uuid[]; begin
  select public.send_friend_request('00000000-0000-4000-8000-0000000000d4') into v_req;

  perform set_config('app.uid', '00000000-0000-4000-8000-0000000000d4', false);
  perform public.respond_to_friend_request((v_req->>'friendship_id')::uuid, true);
  perform set_config('app.uid', '00000000-0000-4000-8000-0000000000b2', false);

  select post_id into v_post from public.feed_page(null, null, 20)
    where author_id = '00000000-0000-4000-8000-0000000000a1' limit 1;
  if v_post is null then raise exception 'FAIL t37b: no Alice post available'; end if;

  select public.add_comment(v_post, 'hi', array['00000000-0000-4000-8000-0000000000d4'::uuid]) into v;
  if (v->>'comment_id') is null then
    raise exception 'FAIL t37b: add_comment was rejected for mentioning a friend who cannot see the post (want silent drop, not rejection)';
  end if;
  v_comment_id := (v->>'comment_id')::uuid;

  select mentioned_user_ids into v_mentions from public.post_comments_page(v_post, null, null, 20)
    where comment_id = v_comment_id and author_id = '00000000-0000-4000-8000-0000000000b2';
  if v_mentions is distinct from array[]::uuid[] then
    raise exception 'FAIL t37b: mention of a friend who cannot see the post was recorded anyway, got %', v_mentions;
  end if;
  raise notice 'PASS t37b: a friend who cannot independently view the post is silently dropped from the mention, not rejected';
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
  if (v->>'status') is distinct from 'open' then raise exception 'FAIL t41: status % (want open)', v->>'status'; end if;
  select reported_user_id, post_id into v_reported, v_linked
    from public.reports where id = (v->>'report_id')::uuid;
  if v_reported is distinct from '00000000-0000-4000-8000-0000000000b2'::uuid then
    raise exception 'FAIL t41: reported_user_id % is not the post author', v_reported; end if;
  if v_linked is distinct from v_post then raise exception 'FAIL t41: report not linked to the post'; end if;
  raise notice 'PASS t41: report_post files against the author and links the post';
end $$;

-- Rewritten per fix-round-1 review: the original ok_self/ok_hidden booleans (bare
-- `exception when others`) passed vacuously even with either app-level guard in report_post
-- deleted outright. Self-reporting is ALSO blocked by the table's own `report_not_self` CHECK
-- (SQLSTATE 23514) once reporter_id = reported_user_id, independent of report_post's
-- `v_author = v_uid` line. Reporting a nonexistent post id also fails independently, on a
-- NOT NULL violation (23502) once v_author resolves to NULL. Both are "some exception", so a
-- deleted app guard was indistinguishable from a working one. Asserting the exact SQLSTATE the
-- APP GUARD itself raises (22023, P0002) closes both holes, and using a post that EXISTS but is
-- INVISIBLE to the caller (rather than a nonexistent id) means NOT NULL can never stand in for
-- the can_view_post gate.
do $$ declare v_own uuid; v_other uuid; ss_self text; ss_hidden text; begin
  select post_id into v_own from public.feed_page(null,null,20)
    where author_id = '00000000-0000-4000-8000-0000000000a1' limit 1;
  if v_own is null then raise exception 'FAIL t42: no own post'; end if;
  -- Capture Barnaby's post while still acting as Alice — Ceri cannot see it, which is the point.
  select post_id into v_other from public.feed_page(null,null,20)
    where author_id = '00000000-0000-4000-8000-0000000000b2' limit 1;
  if v_other is null then raise exception 'FAIL t42: no Barnaby post'; end if;

  begin perform public.report_post(v_own, 'inappropriate_text', null);
  exception when others then ss_self := sqlstate; end;
  if ss_self is distinct from '22023' then
    raise exception 'FAIL t42: self-report rejected with % (want 22023 from the app guard, not the table CHECK)', ss_self; end if;

  perform set_config('app.uid','00000000-0000-4000-8000-0000000000c3', false);
  begin perform public.report_post(v_other, 'inappropriate_text', null);
  exception when others then ss_hidden := sqlstate; end;
  if ss_hidden is distinct from 'P0002' then
    raise exception 'FAIL t42: invisible-post report rejected with % (want P0002)', ss_hidden; end if;
  raise notice 'PASS t42: self-reports and reports of invisible posts are rejected by the app guards';
end $$;

-- I4, take 2 (fix-round-2): the first version of this test had Alice as both the post's author
-- and the reporter, so under the EXACT regression it exists to catch — report_comment resolving
-- v_author from the POST's author instead of the COMMENT's — v_author became Alice, which equalled
-- v_uid (Alice), and report_comment's OWN self-report guard raised 22023 before v_reported/v_linked
-- were ever computed. The suite still went red, but the author-resolution assertion never ran —
-- the same masking pattern as the original t42. Fixed by making the reporter distinct from BOTH
-- the post author and the comment author: Alice authors the post, Ceri (Alice's friend) comments,
-- Barnaby (also Alice's friend, not blocked with Ceri) reports. Under the regression, v_author
-- resolves to Alice, which is neither Barnaby (the self-report guard does not fire) nor Ceri (the
-- true comment author) — the insert SUCCEEDS with the wrong reported_user_id, and that is exactly
-- what the assertion below catches. ids are captured directly from each RPC's own return value
-- (never re-queried via feed_page/post_comments_page), so there is no multi-author ambiguity to
-- guard against here.
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000a1';
do $$ declare v_post uuid; v_comment uuid; v jsonb; v_reported uuid; v_linked uuid; begin
  select public.create_post('t43 setup: Alice post, Ceri comments, Barnaby reports', null, null, null) into v;
  v_post := (v->>'post_id')::uuid;
  if v_post is null then raise exception 'FAIL t43: no post_id from create_post'; end if;

  perform set_config('app.uid', '00000000-0000-4000-8000-0000000000c3', false);
  select public.add_comment(v_post, 'Ceri comment to be reported by Barnaby', null) into v;
  v_comment := (v->>'comment_id')::uuid;
  if v_comment is null then raise exception 'FAIL t43: no comment_id from add_comment'; end if;

  perform set_config('app.uid', '00000000-0000-4000-8000-0000000000b2', false);
  select public.report_comment(v_comment, 'inappropriate_text', 'rude') into v;
  if (v->>'report_id') is null then raise exception 'FAIL t43: report_comment returned no id'; end if;
  if (v->>'status') is distinct from 'open' then raise exception 'FAIL t43: status % (want open)', v->>'status'; end if;

  select reported_user_id, comment_id into v_reported, v_linked
    from public.reports where id = (v->>'report_id')::uuid;
  if v_reported is distinct from '00000000-0000-4000-8000-0000000000c3'::uuid then
    raise exception 'FAIL t43: reported_user_id % is not the COMMENT author (Ceri)', v_reported; end if;
  if v_linked is distinct from v_comment then raise exception 'FAIL t43: report not linked to the comment'; end if;
  raise notice 'PASS t43: report_comment files against the comment author (not the post author), even with reporter, post author and comment author all distinct';
end $$;

-- t43 leaves the session identity as Barnaby (the reporter); reset to Alice before the blocks
-- below, which each assume "Alice, commenting on her own post", as the surrounding style does.
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000a1';

-- t43b: self-reporting your own comment is refused, on the app guard's own errcode.
do $$ declare v_post uuid; v_comment uuid; v jsonb; ss text; begin
  select public.create_post('t43b setup: Alice post for self-report-comment check', null, null, null) into v;
  v_post := (v->>'post_id')::uuid;
  select public.add_comment(v_post, 'Alice commenting on her own post', null) into v;
  v_comment := (v->>'comment_id')::uuid;

  begin perform public.report_comment(v_comment, 'inappropriate_text', null);
  exception when others then ss := sqlstate; end;
  if ss is distinct from '22023' then
    raise exception 'FAIL t43b: self-report-comment rejected with % (want 22023)', ss; end if;
  raise notice 'PASS t43b: cannot report your own comment';
end $$;

-- t43c: a soft-deleted comment cannot be reported — report_comment's query filters
-- `deleted_at is null`, so a deleted comment resolves v_author to NULL, the same failure mode a
-- nonexistent id would hit, but reached via an actually-existing row.
do $$ declare v_post uuid; v_comment uuid; v jsonb; ss text; begin
  select public.create_post('t43c setup: Alice post for deleted-comment report check', null, null, null) into v;
  v_post := (v->>'post_id')::uuid;
  select public.add_comment(v_post, 'will be deleted', null) into v;
  v_comment := (v->>'comment_id')::uuid;
  perform public.delete_comment(v_comment);

  begin perform public.report_comment(v_comment, 'inappropriate_text', null);
  exception when others then ss := sqlstate; end;
  if ss is distinct from 'P0002' then
    raise exception 'FAIL t43c: soft-deleted comment report rejected with % (want P0002)', ss; end if;
  raise notice 'PASS t43c: cannot report a soft-deleted comment';
end $$;

-- t43d: a comment on a post the caller cannot see is refused, even holding the comment id
-- directly — mirrors t42's "invisible post" case, but for comments. Barnaby comments on his own
-- post; Ceri is not Barnaby's friend and nobody is blocked, so this pins the friends-only gate,
-- not a block check.
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000b2';
do $$ declare v_post uuid; v_comment uuid; v jsonb; ss text; begin
  select public.create_post('t43d setup: Barnaby post for invisible-comment report check', null, null, null) into v;
  v_post := (v->>'post_id')::uuid;
  select public.add_comment(v_post, 'Barnaby comment Ceri cannot see', null) into v;
  v_comment := (v->>'comment_id')::uuid;

  perform set_config('app.uid', '00000000-0000-4000-8000-0000000000c3', false);
  begin perform public.report_comment(v_comment, 'inappropriate_text', null);
  exception when others then ss := sqlstate; end;
  if ss is distinct from 'P0002' then
    raise exception 'FAIL t43d: invisible-post comment report rejected with % (want P0002)', ss; end if;
  raise notice 'PASS t43d: cannot report a comment on a post you cannot see';
end $$;

-- t43e: report details are stripped of control/zero-width/bidi characters before storage, exactly
-- like create_post's body and add_comment's body. Both report RPCs previously applied only
-- left(..., 1000), so a bidi override or a zero-width run landed verbatim in reports.details — the
-- one column whose whole purpose is to be read by a human moderator deciding whether text is
-- abusive, i.e. the worst place to let a reporter scramble or spoof what is displayed.
--
-- The payload mixes every class strip_ugc_control_chars handles: a zero-width space (8203), a
-- right-to-left override (8237), a word joiner (8288), an isolate pair (8294/8297), and a C0
-- control (a tab, 9). The expectation is a literal, not a re-derivation of the input, so the
-- assertion cannot pass by accident.
--
-- Note the tab is *deleted*, not turned into a space: `[[:cntrl:]]` removes it, so 've' and 'text'
-- run together. That differs from the client's ProfileTextSanitizer, which maps tabs to spaces
-- before sending precisely so words don't get glued — the same divergence create_post has always
-- had, and harmless because the client sanitises first. Pinned here as the server's own behaviour
-- rather than quietly assumed.
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000a1';
do $$
declare v jsonb; v_post uuid; v_comment uuid; v_details text; v_payload text;
begin
  v_payload := 'ab' || chr(8203) || 'us' || chr(8237) || 'i' || chr(8288) || 've' ||
               chr(8294) || 'x' || chr(8297) || chr(9) || 'text';

  -- report_post: Alice reports one of Barnaby's posts (she can see it; they are friends).
  perform set_config('app.uid', '00000000-0000-4000-8000-0000000000b2', false);
  select public.create_post('t43e setup: Barnaby post for the details-stripping check', null, null, null) into v;
  v_post := (v->>'post_id')::uuid;
  perform set_config('app.uid', '00000000-0000-4000-8000-0000000000a1', false);

  select public.report_post(v_post, 'inappropriate_text', v_payload) into v;
  select details into v_details from public.reports where id = (v->>'report_id')::uuid;
  if v_details is distinct from 'abusivextext' then
    raise exception 'FAIL t43e: report_post stored details % (want ''abusivextext'')', v_details; end if;

  -- report_comment: same payload, same requirement.
  perform set_config('app.uid', '00000000-0000-4000-8000-0000000000b2', false);
  select public.add_comment(v_post, 'Barnaby comment for the details-stripping check', null) into v;
  v_comment := (v->>'comment_id')::uuid;
  perform set_config('app.uid', '00000000-0000-4000-8000-0000000000a1', false);

  select public.report_comment(v_comment, 'inappropriate_text', v_payload) into v;
  select details into v_details from public.reports where id = (v->>'report_id')::uuid;
  if v_details is distinct from 'abusivextext' then
    raise exception 'FAIL t43e: report_comment stored details % (want ''abusivextext'')', v_details; end if;

  -- The length bound still applies on top of the stripping.
  select public.report_post(v_post, 'inappropriate_text', repeat('z', 1500)) into v;
  select details into v_details from public.reports where id = (v->>'report_id')::uuid;
  if char_length(v_details) <> 1000 then
    raise exception 'FAIL t43e: details length % (want 1000)', char_length(v_details); end if;

  -- ...and the paragraphs the reporter typed must reach the moderator. The details field is
  -- `axis: .vertical` with `lineLimit(3...6)`, so someone describing an incident writes several
  -- lines; the single-line stripper deleted every one of them. The tab below still goes and the run
  -- of blank lines still collapses to one, so this is not "controls are no longer stripped".
  select public.report_post(v_post, 'harassment',
                            'what happened' || chr(9) || chr(13) || chr(10) ||
                            'then this' || repeat(chr(10), 4) || 'and this') into v;
  select details into v_details from public.reports where id = (v->>'report_id')::uuid;
  if v_details is distinct from 'what happened' || chr(10) || 'then this' || chr(10) || chr(10) || 'and this' then
    raise exception 'FAIL t43e: report_post flattened multi-line details to %', quote_literal(v_details); end if;

  select public.report_comment(v_comment, 'harassment', 'first line' || chr(10) || 'second line') into v;
  select details into v_details from public.reports where id = (v->>'report_id')::uuid;
  if v_details is distinct from 'first line' || chr(10) || 'second line' then
    raise exception 'FAIL t43e: report_comment flattened multi-line details to %', quote_literal(v_details); end if;

  raise notice 'PASS t43e: report_post/report_comment strip control, zero-width and bidi characters from details';
end $$;

-- t43f: the same requirement for report_user, which writes the SAME reports.details column read by
-- the SAME human moderator, but was left out when t43e's fix landed — it still did
-- left(coalesce(p_details, ''), 1000) with no strip_ugc_control_chars, so the whole payload class
-- t43e blocks on the two content paths stayed reachable through the user-report path
-- (FriendProfileView → ReportUserView → report_user).
--
-- Deliberately identical payload and identical literal expectation to t43e: if the three report
-- RPCs ever diverge again on this column, exactly one of the two tests fails and names which path
-- regressed. No `exception when others` handler here — this is a positive assertion (store, read
-- back, compare against a literal), so there is no handler to swallow it.
--
-- Alice has filed 4 successful reports by this point (t41, t43e×3); the 'report' rate limit is
-- 20/hour, so the two calls below stay well inside it.
do $$
declare v jsonb; v_details text; v_payload text;
begin
  v_payload := 'ab' || chr(8203) || 'us' || chr(8237) || 'i' || chr(8288) || 've' ||
               chr(8294) || 'x' || chr(8297) || chr(9) || 'text';

  select public.report_user('00000000-0000-4000-8000-0000000000b2', 'inappropriate_text', v_payload) into v;
  select details into v_details from public.reports where id = (v->>'report_id')::uuid;
  if v_details is distinct from 'abusivextext' then
    raise exception 'FAIL t43f: report_user stored details % (want ''abusivextext'')', v_details; end if;

  -- The length bound still applies on top of the stripping, as it did before.
  select public.report_user('00000000-0000-4000-8000-0000000000b2', 'other', repeat('z', 1500)) into v;
  select details into v_details from public.reports where id = (v->>'report_id')::uuid;
  if char_length(v_details) <> 1000 then
    raise exception 'FAIL t43f: details length % (want 1000)', char_length(v_details); end if;

  -- And the same multi-line requirement as t43e: one column, one behaviour, three RPCs.
  select public.report_user('00000000-0000-4000-8000-0000000000b2', 'harassment',
                            'first line' || chr(13) || chr(10) || 'second line') into v;
  select details into v_details from public.reports where id = (v->>'report_id')::uuid;
  if v_details is distinct from 'first line' || chr(10) || 'second line' then
    raise exception 'FAIL t43f: report_user flattened multi-line details to %', quote_literal(v_details); end if;

  raise notice 'PASS t43f: report_user strips control, zero-width and bidi characters from details';
end $$;

-- ============================ FEED: comment_count block/soft-delete parity (I1) ============================
-- feed_page's comment_count previously counted every non-deleted comment regardless of the
-- viewer's relationship to the comment's author, while post_comments_page (the actual thread
-- read) already excluded comments by blocked authors and soft-deleted profiles
-- (20260811000600_rpc_feed_social.sql:203-205). That mismatch let a feed row advertise "1
-- comment" for a thread that opens empty, leaking that a blocked user is still active. Ceri
-- becomes Barnaby's friend so she can legitimately comment on his post; Alice then blocks Ceri
-- and must see the count drop to zero, matching the (already-correct) empty thread read.
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000c3';
do $$ declare v_req jsonb; begin
  select public.send_friend_request('00000000-0000-4000-8000-0000000000b2') into v_req;
  perform set_config('app.uid', '00000000-0000-4000-8000-0000000000b2', false);
  perform public.respond_to_friend_request((v_req->>'friendship_id')::uuid, true);
  raise notice 'PASS t44 setup: Ceri and Barnaby become friends';
end $$;

do $$ declare v jsonb; begin
  select public.create_post('t44 setup: Barnaby post for the comment_count check', null, null, null) into v;
  if (v->>'post_id') is null then raise exception 'FAIL t44: Barnaby could not create a post'; end if;
  raise notice 'PASS t44 setup: Barnaby creates a post for the comment_count check';
end $$;

reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000c3';
do $$ declare v_post uuid; begin
  select post_id into v_post from public.feed_page(null, null, 20)
    where author_id = '00000000-0000-4000-8000-0000000000b2'
    order by created_at desc limit 1;
  if v_post is null then raise exception 'FAIL t44: no Barnaby post available for Ceri to comment on'; end if;
  perform public.add_comment(v_post, 'Ceri comment that Alice must not be able to count', null);
  raise notice 'PASS t44 setup: Ceri comments on Barnaby''s post';
end $$;

reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000a1';
do $$ begin
  perform public.block_user('00000000-0000-4000-8000-0000000000c3');
  raise notice 'PASS t44 setup: Alice blocks Ceri';
end $$;

do $$ declare v_post uuid; v_count int; v_thread_count int; begin
  select post_id into v_post from public.feed_page(null, null, 20)
    where author_id = '00000000-0000-4000-8000-0000000000b2'
    order by created_at desc limit 1;
  if v_post is null then raise exception 'FAIL t44: Alice cannot see Barnaby''s post at all'; end if;

  select comment_count into v_count from public.feed_page(null, null, 20)
    where author_id = '00000000-0000-4000-8000-0000000000b2' and post_id = v_post;
  if v_count is distinct from 0 then
    raise exception 'FAIL t44: Alice''s feed shows comment_count % for a post whose only comment is from someone she blocked (want 0)', v_count;
  end if;

  select count(*) into v_thread_count from public.post_comments_page(v_post, null, null, 20)
    where author_id = '00000000-0000-4000-8000-0000000000c3';
  if v_thread_count is distinct from 0 then
    raise exception 'FAIL t44: Alice''s thread read returned % comments from the blocked author Ceri (want 0)', v_thread_count;
  end if;

  raise notice 'PASS t44: feed_page.comment_count excludes comments by a blocked author, matching post_comments_page''s empty thread';
end $$;

-- ============================ FEED: feed_page avatar-visibility gate (I12) ============================
-- feed_page's avatar gate (20260811000500_rpc_feed_posts.sql:133-134) had zero test coverage —
-- t36a covers post_comments_page's equivalent gate, but nothing here ever checked feed_page's own
-- gate in either direction. Barnaby's avatar_path was set to 'b2/barnaby.jpg' back in t36a and his
-- avatar_visibility still defaults to 'friends'. This pins BOTH failure directions the gate could
-- silently regress to: (1) a friend must actually RECEIVE the avatar under the default
-- avatar_visibility = 'friends' — a regression that collapsed the gate to "self only" (e.g. the
-- `or ps.avatar_visibility = 'friends'` clause deleted outright) would still coincidentally pass a
-- test that only ever checked the 'private' case, since a friend gets NULL either way once
-- visibility is private; (2) flipping to avatar_visibility = 'private' must then blank the field
-- for that same friend, while the author reading their own post still gets the path regardless.
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000a1';
do $$ declare v_avatar_friend text; v_post uuid; begin
  select post_id, avatar_path into v_post, v_avatar_friend from public.feed_page(null, null, 20)
    where author_id = '00000000-0000-4000-8000-0000000000b2'
    order by created_at desc limit 1;
  if v_post is null then raise exception 'FAIL t45: Alice cannot see any Barnaby post'; end if;
  if v_avatar_friend is distinct from 'b2/barnaby.jpg' then
    raise exception 'FAIL t45: Alice (a friend) did not receive Barnaby''s avatar_path under the default avatar_visibility = friends, got %', v_avatar_friend;
  end if;
  raise notice 'PASS t45: feed_page grants a friend the avatar_path when avatar_visibility = friends (the default)';
end $$;

reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000b2';
do $$ begin
  update public.privacy_settings set avatar_visibility = 'private' where user_id = auth.uid();
  raise notice 'PASS t45 setup: Barnaby sets avatar_visibility to private';
end $$;

do $$ declare v_avatar_self text; v_post uuid; begin
  select post_id, avatar_path into v_post, v_avatar_self from public.feed_page(null, null, 20)
    where author_id = '00000000-0000-4000-8000-0000000000b2'
    order by created_at desc limit 1;
  if v_post is null then raise exception 'FAIL t45: no Barnaby post available'; end if;
  if v_avatar_self is distinct from 'b2/barnaby.jpg' then
    raise exception 'FAIL t45: Barnaby reading his own feed row got avatar_path %, want his own path regardless of avatar_visibility', v_avatar_self;
  end if;
  raise notice 'PASS t45: the post author still sees their own avatar_path with avatar_visibility = private';
end $$;

reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000a1';
do $$ declare v_avatar_friend text; v_post uuid; begin
  select post_id, avatar_path into v_post, v_avatar_friend from public.feed_page(null, null, 20)
    where author_id = '00000000-0000-4000-8000-0000000000b2'
    order by created_at desc limit 1;
  if v_post is null then raise exception 'FAIL t45: Alice cannot see any Barnaby post'; end if;
  if v_avatar_friend is not null then
    raise exception 'FAIL t45: Alice (a friend) received Barnaby''s avatar_path % despite avatar_visibility = private', v_avatar_friend;
  end if;
  raise notice 'PASS t45: feed_page blanks avatar_path for a friend when the author''s avatar_visibility = private';
end $$;

reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000b2';
do $$ begin
  update public.privacy_settings set avatar_visibility = 'friends' where user_id = auth.uid();
  raise notice 'PASS t45 cleanup: Barnaby restores avatar_visibility to friends';
end $$;

reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000a1';

-- ============================ STORAGE: private post photos ============================
-- The suite's shim gives storage.objects RLS but no policies, so these assertions exercise the
-- policy we are about to add. Rows are inserted with the service role (reset role) because the
-- shim grants no INSERT policy on storage.objects.
reset role;
insert into storage.objects (bucket_id, name)
values ('post-images', '00000000-0000-4000-8000-0000000000b2/barnaby-pint.jpg')
on conflict do nothing;

-- Give Barnaby a post that references it so the policy has something to join to.
set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000b2';

-- t44 (above) made Ceri and Barnaby accepted friends so she could legitimately comment on his
-- post for the comment_count check, and nothing since has undone it. This test needs Ceri back to
-- her original "Alice's friend, NOT Barnaby's" seed relationship to exercise the non-friend
-- denial below — without this, the negative assertion would be testing an accepted friend and
-- would pass for the wrong reason (or, as currently written, fail outright).
do $$ begin
  perform public.remove_friend('00000000-0000-4000-8000-0000000000c3');
  raise notice 'PASS t46 setup: Barnaby and Ceri''s t44 friendship is undone so Ceri is a non-friend again';
end $$;

do $$ begin
  perform public.create_post('storage policy fixture', '00000000-0000-4000-8000-0000000000b2/barnaby-pint.jpg', null, null);
end $$;

do $$ declare v_bucket_public boolean; visible int; begin
  select public.bucket_is_public('post-images') into v_bucket_public;
  if v_bucket_public is distinct from false then
    raise exception 'FAIL t46: post-images bucket is still public'; end if;

  -- Author sees their own object.
  select count(*) into visible from storage.objects
   where bucket_id = 'post-images' and name like '00000000-0000-4000-8000-0000000000b2/%';
  if visible is distinct from 1 then
    raise exception 'FAIL t46: author sees % of own objects (want 1)', visible; end if;
  raise notice 'PASS t46: the bucket is private and the author can read their own photo';
end $$;

-- Alice is Barnaby's accepted friend -> may read.
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000a1';
do $$ declare visible int; begin
  select count(*) into visible from storage.objects
   where bucket_id = 'post-images' and name like '00000000-0000-4000-8000-0000000000b2/%';
  if visible is distinct from 1 then
    raise exception 'FAIL t46: friend sees % (want 1)', visible; end if;
  raise notice 'PASS t46: an accepted friend can read the photo';
end $$;

-- Ceri is Alice's friend but NOT Barnaby's -> must not read.
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000c3';
do $$ declare visible int; begin
  select count(*) into visible from storage.objects
   where bucket_id = 'post-images' and name like '00000000-0000-4000-8000-0000000000b2/%';
  if visible is distinct from 0 then
    raise exception 'FAIL t46: non-friend sees % objects (want 0)', visible; end if;
  raise notice 'PASS t46: a non-friend cannot read the photo';
end $$;

-- Revocation: the whole point of going private is that deleting the post revokes access to the
-- photo immediately, not just "post deletion no longer matters because the URL was already
-- public." Barnaby soft-deletes his post; Alice, who could read the photo a moment ago as an
-- accepted friend, must now see zero objects. Nothing else exercises the policy's
-- `p.deleted_at is null` clause.
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000b2';
do $$ declare v_post uuid; begin
  -- public.posts is RLS-enabled with no policies (see the migration's can_read_post_image
  -- comment) — a direct select here would return nothing even for Barnaby himself. feed_page is
  -- the security-definer path every other test in this suite already uses to fetch a post id.
  select post_id into v_post from public.feed_page(null, null, 20)
   where author_id = '00000000-0000-4000-8000-0000000000b2'
     and image_path = '00000000-0000-4000-8000-0000000000b2/barnaby-pint.jpg';
  if v_post is null then raise exception 'FAIL t46: storage fixture post not found to delete'; end if;
  perform public.delete_post(v_post);
  raise notice 'PASS t46 setup: Barnaby deletes the fixture post';
end $$;

reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000a1';
do $$ declare visible int; begin
  select count(*) into visible from storage.objects
   where bucket_id = 'post-images' and name like '00000000-0000-4000-8000-0000000000b2/%';
  if visible is distinct from 0 then
    raise exception 'FAIL t46: friend still sees % objects after the post was deleted (want 0)', visible; end if;
  raise notice 'PASS t46: deleting the post immediately revokes the friend''s access to the photo';
end $$;

-- ============================ STORAGE GC QUEUE ============================
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000a1';
do $$ declare visible int; begin
  select count(*) into visible from public.storage_gc_queue;
  if visible is distinct from 0 then
    raise exception 'FAIL t47: storage_gc_queue exposed % rows to a client', visible; end if;
  raise notice 'PASS t47: the GC queue is invisible to clients';
end $$;

do $$ declare ok boolean := false; begin
  begin
    perform public.enqueue_storage_object('post-images', 'x/y.jpg');
  exception when others then ok := true;
  end;
  if not ok then raise exception 'FAIL t47: a client could enqueue a GC entry'; end if;
  raise notice 'PASS t47: clients cannot enqueue GC work directly';
end $$;

-- ============================ STORAGE GC QUEUE: claim marker + failure record ============================
-- Owner-only setup (reset role), same as the storage fixture insert above (t46 setup): these
-- maintenance functions are revoked from authenticated, and postgres is a superuser so grants
-- don't gate it anyway.
reset role;
do $$ declare v_id uuid; v_attempts int; begin
  perform public.enqueue_storage_object('post-images', 'gc-claim-marker-test/t48.jpg');
  select id into v_id from public.storage_gc_queue
   where bucket_id = 'post-images' and object_path = 'gc-claim-marker-test/t48.jpg';
  if v_id is null then
    raise exception 'FAIL t48: enqueue_storage_object did not create the fixture row'; end if;

  perform public.claim_storage_gc(10);
  select attempts into v_attempts from public.storage_gc_queue where id = v_id;
  if v_attempts is distinct from 1 then
    raise exception 'FAIL t48: attempts after one claim was % (want 1)', v_attempts; end if;

  perform public.claim_storage_gc(10);
  select attempts into v_attempts from public.storage_gc_queue where id = v_id;
  if v_attempts is distinct from 2 then
    raise exception 'FAIL t48: attempts after a second claim was % (want 2)', v_attempts; end if;

  raise notice 'PASS t48: claim_storage_gc increments attempts on every claim';
end $$;

do $$ declare v_id uuid; v_processed timestamptz; v_error text; begin
  select id into v_id from public.storage_gc_queue
   where bucket_id = 'post-images' and object_path = 'gc-claim-marker-test/t48.jpg';
  if v_id is null then
    raise exception 'FAIL t48: fixture row from the previous assertion is missing'; end if;

  perform public.mark_storage_gc_failed(array[v_id], 'simulated remove() failure for t48');

  select processed_at, last_error into v_processed, v_error
    from public.storage_gc_queue where id = v_id;

  if v_processed is distinct from null then
    raise exception
      'FAIL t48: mark_storage_gc_failed set processed_at to % (want it left null so the row stays claimable)',
      v_processed; end if;
  if v_error is distinct from 'simulated remove() failure for t48' then
    raise exception 'FAIL t48: last_error was % (want the recorded message)', v_error; end if;

  raise notice 'PASS t48: mark_storage_gc_failed records last_error and leaves the row claimable';
end $$;

-- ============================ RETENTION ============================
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000a1';
do $$ declare v jsonb; v_post uuid; queued int; begin
  select public.create_post('retention fixture', '00000000-0000-4000-8000-0000000000a1/retain.jpg', null, null) into v;
  v_post := (v->>'post_id')::uuid;
  perform public.delete_post(v_post);
  reset role;
  select count(*) into queued from public.storage_gc_queue
   where bucket_id = 'post-images' and object_path = '00000000-0000-4000-8000-0000000000a1/retain.jpg';
  if queued is distinct from 1 then
    raise exception 'FAIL t49: deleting a post queued % GC entries (want 1)', queued; end if;
  raise notice 'PASS t49: deleting a post queues its photo for storage deletion';
end $$;

reset role;
do $$ declare purged int; still int; begin
  -- Age the soft-deleted rows past the retention window, then purge.
  update public.posts set deleted_at = now() - interval '40 days' where deleted_at is not null;
  select public.purge_soft_deleted_posts(interval '30 days') into purged;
  if purged < 1 then raise exception 'FAIL t50: purge removed % posts (want >=1)', purged; end if;
  select count(*) into still from public.posts where deleted_at < now() - interval '30 days';
  if still is distinct from 0 then
    raise exception 'FAIL t50: % aged soft-deleted posts survived the purge', still; end if;
  raise notice 'PASS t50: aged soft-deleted posts are purged';
end $$;

-- t50 (ordering): the assertions above re-purge the SAME path t49 already queued via
-- delete_post's own enqueue, so storage_gc_queue's `unique (bucket_id, object_path)` makes
-- purge's re-enqueue a no-op regardless of whether purge enqueues before or after deleting —
-- deleting the row first and then re-purging still leaves `purged >= 1` and `still = 0`. Confirmed
-- empirically: swapping purge_soft_deleted_posts to delete before enqueuing left every assertion
-- above green. This block closes that gap by inserting a fixture directly (bypassing delete_post
-- entirely, so its image was NEVER queued by anything else) and checking that purge itself queued
-- it — which only holds if the enqueue happened before the row, and its image_path, were deleted.
reset role;
do $$ declare v_post uuid; queued int; begin
  insert into public.posts (author_id, body, image_path, deleted_at)
  values ('00000000-0000-4000-8000-0000000000a1', 'retention ordering fixture',
          '00000000-0000-4000-8000-0000000000a1/retain-ordering.jpg', now() - interval '40 days')
  returning id into v_post;

  perform public.purge_soft_deleted_posts(interval '30 days');

  select count(*) into queued from public.storage_gc_queue
   where bucket_id = 'post-images'
     and object_path = '00000000-0000-4000-8000-0000000000a1/retain-ordering.jpg';
  if queued is distinct from 1 then
    raise exception 'FAIL t50: purge queued % GC entries for a fixture it just deleted (want 1)', queued; end if;
  raise notice 'PASS t50: purge_soft_deleted_posts enqueues the photo before deleting the row';
end $$;

reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000a1';
do $$ declare ok boolean := false; begin
  begin
    perform public.purge_soft_deleted_posts(interval '30 days');
  exception when others then ok := true;
  end;
  if not ok then raise exception 'FAIL t50: a client could run a retention purge'; end if;
  raise notice 'PASS t50: retention purges are not client-callable';
end $$;

-- ============================ DATA EXPORT (Art. 15 / 20) ============================
-- Fix round 1 (mutation testing): cheers_given, blocks and mentioned_user_ids were previously
-- untestable because the fixture data never gave a wrong filter anything *different* to
-- return (post_cheers was empty; only Alice had ever placed a block; no comment's mentions
-- were read at all). Every setup step below exists to give a specific predicate real,
-- non-vacuous, foreign-tainted data so its ownership assertion can actually fire.

-- t51 setup (Alice): a fresh post to cheer/comment on, a comment mentioning her friend
-- Barnaby, a report she files against him, a pub preference, a Nudge to him, and a pint entry
-- carrying a private note.
--
-- The noted entry exists because nothing anywhere asserted that private_note survives into the
-- Art. 15 export: the seeded entries all leave the column NULL, so dropping
-- `'private_note', e.private_note` from export_my_data left this suite green. It is the one column
-- in pint_entries that holds the user's own words, so its absence from a data export would be the
-- omission a data-subject request would actually notice. Every exact pint-count assertion in this
-- suite (t5's `v_alice <> 3`, the `count(*) <> 4` RLS check) runs far earlier than this, so the
-- extra row cannot disturb them.
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000a1';
do $$ declare v jsonb; v_post uuid; begin
  select public.create_post('t51 fixture: alice export post', null, null, null) into v;
  v_post := (v->>'post_id')::uuid;
  perform public.add_comment(v_post, 't51 fixture: alice mentions barnaby',
                              array['00000000-0000-4000-8000-0000000000b2']::uuid[]);
  perform public.toggle_post_cheers(v_post);
  perform public.report_user('00000000-0000-4000-8000-0000000000b2', 'other',
                              't51 fixture: alice reports barnaby');
  insert into public.user_pub_preferences (user_id, pub_id, hidden_from_favourites)
  values ('00000000-0000-4000-8000-0000000000a1', '00000000-0000-4000-8000-00000000e001', true)
  on conflict (user_id, pub_id) do update set hidden_from_favourites = true;
  perform public.send_nudge('00000000-0000-4000-8000-0000000000b2');
  perform public.create_pint_entry('t51-noted', now(), 'pint', null, false, null, null,
                                   't51 fixture: alice private note');
  raise notice 'PASS t51 setup: Alice creates a fixture post, cheers it, comments mentioning Barnaby, reports Barnaby, sets a pub preference, Nudges Barnaby, and logs a pint with a private note';
end $$;

-- t51 setup (Barnaby): cheers Alice's fixture post (I1 — a foreign cheerer on a post Alice
-- authored, the exact shape the "who cheered my post" mutation would leak); @mentions Dev in
-- his OWN post, then blocks Dev (I2 — a foreign blocker_id; I3 — a foreign mentioned_user_id
-- that must not leak into Alice's comments); Nudges Alice back. Barnaby and Dev are ALREADY
-- accepted friends from t37b's setup (never undone, unlike the Barnaby–Ceri pair t46 removes),
-- so no fresh friend request is needed here — sending one would just hit send_friend_request's
-- "reuse any existing live edge" branch and come back already 'accepted', not 'pending'.
--
-- Fix round 2: also hosts his own pub session and sets his own pub preference. Round 1's
-- pub_sessions/user_pub_preferences fixtures were Alice-only (the seeded session at
-- seed.sql:82-86 and Alice's own preference above are the ONLY rows in either table), so an
-- unfiltered read returned nothing different from a correctly-filtered one and the ownership
-- assertions for those two keys could not fire. create_pub_session() is the real client RPC
-- for sessions (20260101000850_rpc_pints_sessions.sql) — used here rather than a raw insert.
-- user_pub_preferences has no dedicated RPC, so this uses a direct insert while running AS
-- authenticated/Barnaby, which the table's own `user_pub_prefs_all_self` RLS policy
-- (`user_id = auth.uid()`, 20260101000700_rls_policies.sql) already permits for a client — not
-- a `reset role` owner-bypass, since a legitimate client-side write path already exists.
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000b2';
do $$ declare v_post uuid; v jsonb; begin
  select post_id into v_post from public.feed_page(null, null, 50)
    where author_id = '00000000-0000-4000-8000-0000000000a1'
      and body = 't51 fixture: alice export post'
    limit 1;
  if v_post is null then
    raise exception 'FAIL t51 setup: Barnaby cannot see Alice''s fixture post'; end if;
  perform public.toggle_post_cheers(v_post);

  select public.create_post('t51 fixture: barnaby post for foreign mention', null, null, null) into v;
  perform public.add_comment((v->>'post_id')::uuid,
    't51 fixture: barnaby mentions dev, must not leak into alice export',
    array['00000000-0000-4000-8000-0000000000d4']::uuid[]);

  perform public.block_user('00000000-0000-4000-8000-0000000000d4');
  perform public.send_nudge('00000000-0000-4000-8000-0000000000a1');

  perform public.create_pub_session('00000000-0000-4000-8000-00000000e002', 't51 fixture: barnaby session');
  insert into public.user_pub_preferences (user_id, pub_id, hidden_from_favourites)
  values ('00000000-0000-4000-8000-0000000000b2', '00000000-0000-4000-8000-00000000e002', true)
  on conflict (user_id, pub_id) do update set hidden_from_favourites = true;

  raise notice 'PASS t51 setup: Barnaby cheers Alice''s post, mentions then blocks Dev, Nudges Alice, hosts his own pub session, and sets his own pub preference';
end $$;

reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000a1';
do $$ declare v jsonb; v_fixture_comment jsonb; begin
  select public.export_my_data() into v;
  if v is null then raise exception 'FAIL t51: export returned null'; end if;
  if (v->'profile'->>'id') is distinct from '00000000-0000-4000-8000-0000000000a1' then
    raise exception 'FAIL t51: export profile id is %', v->'profile'->>'id'; end if;

  -- I4: privacy_settings must name its own owner. Previously nothing in the object could
  -- confirm whose nine visibility switches these were, so a `where s.user_id <> v_uid` mutation
  -- handed the caller another user's settings and this suite stayed green.
  if (v->'privacy_settings'->>'user_id') is distinct from '00000000-0000-4000-8000-0000000000a1' then
    raise exception 'FAIL t51: privacy_settings.user_id is %, not the caller', v->'privacy_settings'->>'user_id';
  end if;

  -- Deliberate exclusion (see migration header): a live invite credential has no place in a
  -- downloadable export, however convenient to include.
  if v ? 'friend_tokens' then
    raise exception 'FAIL t51: export must not include friend_tokens (live invite credential)'; end if;

  if jsonb_typeof(v->'pint_entries') is distinct from 'array' then
    raise exception 'FAIL t51: pint_entries is not an array'; end if;
  if jsonb_array_length(v->'pint_entries') < 1 then
    raise exception 'FAIL t51: export contains no pint entries for a user who has 5'; end if;

  -- Art. 15: the note is the only free text in a pint entry, so it must be IN the export. Asserted
  -- against the fixture's literal text, not merely "the key exists", so exporting a NULL for a row
  -- that has a note fails too.
  if not exists (
    select 1 from jsonb_array_elements(v->'pint_entries') e
     where (e->>'private_note') = 't51 fixture: alice private note'
  ) then raise exception 'FAIL t51: export dropped pint_entries.private_note (Art. 15)'; end if;

  -- The export must be caller-scoped: no other user's rows may appear, in ANY collection — a
  -- missing auth.uid() filter anywhere is a data breach, not just an over-return. Every
  -- assertion below now has a non-vacuous, foreign-tainted fixture behind it (see t51 setup
  -- above), so a wrong filter has something real to leak, not an empty table to pass over.
  if exists (
    select 1 from jsonb_array_elements(v->'pint_entries') e
     where (e->>'user_id') is distinct from '00000000-0000-4000-8000-0000000000a1'
  ) then raise exception 'FAIL t51: export leaked another user''s pint entries'; end if;

  if exists (
    select 1 from jsonb_array_elements(v->'posts') e
     where (e->>'author_id') is distinct from '00000000-0000-4000-8000-0000000000a1'
  ) then raise exception 'FAIL t51: export leaked another user''s posts'; end if;

  if exists (
    select 1 from jsonb_array_elements(v->'comments') e
     where (e->>'author_id') is distinct from '00000000-0000-4000-8000-0000000000a1'
  ) then raise exception 'FAIL t51: export leaked another user''s comments'; end if;

  -- I3: mentioned_user_ids must be a (possibly empty) array on every comment, at least one
  -- comment must carry a non-empty list, Alice's own fixture comment must still contain the
  -- friend she actually mentioned (Barnaby), and it must NOT contain the foreign target
  -- Barnaby separately mentioned in his own comment (Dev). That last check is what catches an
  -- uncorrelated read pulling every mention on the platform into every comment; the "contains
  -- Barnaby" check is what catches the correlation being silently flipped to inbound mentions.
  if exists (
    select 1 from jsonb_array_elements(v->'comments') e
     where jsonb_typeof(e->'mentioned_user_ids') is distinct from 'array'
  ) then raise exception 'FAIL t51: a comment''s mentioned_user_ids is not an array'; end if;
  if not exists (
    select 1 from jsonb_array_elements(v->'comments') e
     where jsonb_array_length(e->'mentioned_user_ids') > 0
  ) then raise exception 'FAIL t51: no comment carries any mentioned_user_ids'; end if;
  select e into v_fixture_comment from jsonb_array_elements(v->'comments') e
   where e->>'body' = 't51 fixture: alice mentions barnaby';
  if v_fixture_comment is null then
    raise exception 'FAIL t51: alice''s fixture comment is missing from the export'; end if;
  if not (v_fixture_comment->'mentioned_user_ids' ? '00000000-0000-4000-8000-0000000000b2') then
    raise exception 'FAIL t51: alice''s fixture comment lost its mention of barnaby: %',
      v_fixture_comment->'mentioned_user_ids';
  end if;
  if v_fixture_comment->'mentioned_user_ids' ? '00000000-0000-4000-8000-0000000000d4' then
    raise exception 'FAIL t51: alice''s fixture comment leaked a foreign mention of dev: %',
      v_fixture_comment->'mentioned_user_ids';
  end if;

  -- I1: cheers_given must be non-empty (Alice really cheered) and every element must be hers —
  -- Barnaby also cheered Alice's fixture post, so a filter mistakenly scoped to "who cheered
  -- posts I authored" instead of "cheers I gave" would leak his row here.
  if jsonb_array_length(v->'cheers_given') < 1 then
    raise exception 'FAIL t51: export contains no cheers for a user who cheered a post'; end if;
  if exists (
    select 1 from jsonb_array_elements(v->'cheers_given') e
     where (e->>'user_id') is distinct from '00000000-0000-4000-8000-0000000000a1'
  ) then raise exception 'FAIL t51: export leaked another user''s cheers'; end if;

  if exists (
    select 1 from jsonb_array_elements(v->'friends') e
     where (e->>'requester_id') is distinct from '00000000-0000-4000-8000-0000000000a1'
       and (e->>'addressee_id') is distinct from '00000000-0000-4000-8000-0000000000a1'
  ) then raise exception 'FAIL t51: export returned a friendship the caller is not party to'; end if;

  -- I2: blocks must be non-empty and every element must be a block Alice PLACED — Barnaby now
  -- also blocks Dev, so an unfiltered (or wrongly-directed) read has a foreign blocker_id to leak.
  if jsonb_array_length(v->'blocks') < 1 then
    raise exception 'FAIL t51: export contains no blocks for a user who has placed one'; end if;
  if exists (
    select 1 from jsonb_array_elements(v->'blocks') e
     where (e->>'blocker_id') is distinct from '00000000-0000-4000-8000-0000000000a1'
  ) then raise exception 'FAIL t51: export leaked a block the caller did not place'; end if;

  -- JC3: reports the caller filed are included, but never the accused party's identity.
  if jsonb_array_length(v->'reports') < 1 then
    raise exception 'FAIL t51: export contains no reports for a user who filed one'; end if;
  if exists (
    select 1 from jsonb_array_elements(v->'reports') e
     where (e->>'reporter_id') is distinct from '00000000-0000-4000-8000-0000000000a1'
  ) then raise exception 'FAIL t51: export leaked a report the caller did not file'; end if;
  if exists (
    select 1 from jsonb_array_elements(v->'reports') e where e ? 'reported_user_id'
  ) then raise exception 'FAIL t51: export exposed reported_user_id on a filed report'; end if;

  if jsonb_array_length(v->'user_pub_preferences') < 1 then
    raise exception 'FAIL t51: export contains no user_pub_preferences for a user who set one'; end if;
  if exists (
    select 1 from jsonb_array_elements(v->'user_pub_preferences') e
     where (e->>'user_id') is distinct from '00000000-0000-4000-8000-0000000000a1'
  ) then raise exception 'FAIL t51: export leaked another user''s pub preferences'; end if;

  if jsonb_array_length(v->'pub_sessions') < 1 then
    raise exception 'FAIL t51: export contains no pub_sessions for a user who hosts one'; end if;
  if exists (
    select 1 from jsonb_array_elements(v->'pub_sessions') e
     where (e->>'host_user_id') is distinct from '00000000-0000-4000-8000-0000000000a1'
  ) then raise exception 'FAIL t51: export leaked a session the caller does not host'; end if;

  if jsonb_array_length(v->'session_members') < 1 then
    raise exception 'FAIL t51: export contains no session_members for a user who joined one'; end if;
  if exists (
    select 1 from jsonb_array_elements(v->'session_members') e
     where (e->>'user_id') is distinct from '00000000-0000-4000-8000-0000000000a1'
  ) then raise exception 'FAIL t51: export leaked another user''s session membership'; end if;

  if jsonb_array_length(v->'nudges_sent') < 1 then
    raise exception 'FAIL t51: export contains no nudges_sent for a user who sent one'; end if;
  if exists (
    select 1 from jsonb_array_elements(v->'nudges_sent') e
     where (e->>'sender_id') is distinct from '00000000-0000-4000-8000-0000000000a1'
  ) then raise exception 'FAIL t51: export leaked a nudge the caller did not send'; end if;

  if jsonb_array_length(v->'nudges_received') < 1 then
    raise exception 'FAIL t51: export contains no nudges_received for a user who received one'; end if;
  if exists (
    select 1 from jsonb_array_elements(v->'nudges_received') e
     where (e->>'recipient_id') is distinct from '00000000-0000-4000-8000-0000000000a1'
  ) then raise exception 'FAIL t51: export leaked a nudge the caller did not receive'; end if;

  -- I5: every collection is far under the 10,000-row cap, so truncated must read false.
  if (v->>'truncated') is distinct from 'false' then
    raise exception 'FAIL t51: truncated is % for fixture data far under the cap', v->>'truncated';
  end if;

  raise notice 'PASS t51: export_my_data returns the caller''s own data only, across all collections';
end $$;

reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000a1';
do $$ declare ok boolean := false; begin
  begin
    perform public.export_my_data();
    perform public.export_my_data();
    perform public.export_my_data();
    perform public.export_my_data();
    perform public.export_my_data();
    perform public.export_my_data();
  exception when others then ok := true;
  end;
  if not ok then raise exception 'FAIL t51: a 6th export in the window was not rate-limited'; end if;
  raise notice 'PASS t51: export_my_data is rate-limited (data_export, 5/24h)';
end $$;

-- ============================ HELPER ORACLES ============================
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000c3';
do $$
declare ok_friend boolean := false; ok_blocked boolean := false; ok_profile boolean := false;
begin
  -- Ceri must not be able to interrogate other people's relationships directly.
  begin
    perform public.is_accepted_friend(
      '00000000-0000-4000-8000-0000000000a1', '00000000-0000-4000-8000-0000000000b2');
  exception when others then ok_friend := true;
  end;
  begin
    perform public.is_blocked(
      '00000000-0000-4000-8000-0000000000a1', '00000000-0000-4000-8000-0000000000d4');
  exception when others then ok_blocked := true;
  end;
  begin
    perform public.can_view_profile(
      '00000000-0000-4000-8000-0000000000a1', '00000000-0000-4000-8000-0000000000b2');
  exception when others then ok_profile := true;
  end;
  if not ok_friend then raise exception 'FAIL t52: is_accepted_friend is a client-callable oracle'; end if;
  if not ok_blocked then raise exception 'FAIL t52: is_blocked is a client-callable oracle'; end if;
  if not ok_profile then raise exception 'FAIL t52: can_view_profile is a client-callable oracle'; end if;
  raise notice 'PASS t52: relationship helpers are not callable by clients';
end $$;

-- ...and the feed still works, i.e. the revoke did not break the definer functions that use them.
do $$ declare visible int; begin
  select count(*) into visible from public.feed_page(null, null, 20);
  if visible < 1 then raise exception 'FAIL t52: feed_page returned % rows after the revoke', visible; end if;
  raise notice 'PASS t52: feed_page still works — nested definer calls are unaffected';
end $$;

-- ============================ UGC STRIPPING ON THE LAST TWO RAW COLUMNS ============================
-- An audit of every client call site that writes user-typed free text found exactly two columns
-- unsanitised on BOTH sides: pub_sessions.name and pint_entries.private_note. Both applied only
-- left(..., N), so the whole payload class t43e/t43f block on posts, comments and reports stayed
-- reachable through the session and pint RPCs.
--
-- Same payload and same literal expectation as t43e/t43f, so if these RPCs ever diverge again from
-- the others exactly one test fails and names the column. Both are positive assertions — write, read
-- back, compare against a literal — so there is no `exception when others` handler to swallow them.
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000a1';

-- t53: pub_sessions.name. This is the cross-user one: ActiveSessionView renders the name as the
-- navigation title for every member of the session, so an unsanitised name is a payload on someone
-- else's screen. Also pins that the 80-code-point bound and the nullif-to-NULL behaviour survive the
-- added strip — a name of nothing but invisible characters must store NULL, not an empty string.
do $$
declare v jsonb; v_name text; v_payload text; v_id uuid;
begin
  v_payload := 'ab' || chr(8203) || 'us' || chr(8237) || 'i' || chr(8288) || 've' ||
               chr(8294) || 'x' || chr(8297) || chr(9) || 'text';

  select public.create_pub_session(null, v_payload) into v;
  v_id := (v->>'session_id')::uuid;
  select name into v_name from public.pub_sessions where id = v_id;
  if v_name is distinct from 'abusivextext' then
    raise exception 'FAIL t53: create_pub_session stored name % (want ''abusivextext'')', v_name; end if;

  -- The length bound still applies on top of the stripping.
  select public.create_pub_session(null, repeat('z', 120)) into v;
  select name into v_name from public.pub_sessions where id = (v->>'session_id')::uuid;
  if char_length(v_name) <> 80 then
    raise exception 'FAIL t53: name length % (want 80)', char_length(v_name); end if;

  -- A name that is nothing but invisible characters is no name at all: nullif must still see ''.
  select public.create_pub_session(null, chr(8203) || chr(8237)) into v;
  select name into v_name from public.pub_sessions where id = (v->>'session_id')::uuid;
  if v_name is not null then
    raise exception 'FAIL t53: invisible-only name stored % (want NULL)', quote_literal(v_name); end if;

  raise notice 'PASS t53: create_pub_session strips control, zero-width and bidi characters from the session name';
end $$;

-- t54: pint_entries.private_note. Private to its author, but read back and displayed, and it was the
-- last column with no strip on either side.
--
-- The third assertion pins the newline behaviour deliberately, because it drives a client decision:
-- strip_ugc_control_chars deletes chr(10) along with every other C0 control character, so this column
-- CANNOT hold a line break. LogPintSheet therefore joins its "[Beer: …]" line to the user's own words
-- with a space; joining with a newline would have the server delete the separator and glue the two
-- halves into one word. Asserted as the server's own behaviour rather than quietly assumed.
do $$
declare v jsonb; v_note text; v_payload text;
begin
  v_payload := 'ab' || chr(8203) || 'us' || chr(8237) || 'i' || chr(8288) || 've' ||
               chr(8294) || 'x' || chr(8297) || chr(9) || 'text';

  select public.create_pint_entry('t54-strip', now(), 'pint', null, false, null, null, v_payload) into v;
  v_note := v->>'private_note';
  if v_note is distinct from 'abusivextext' then
    raise exception 'FAIL t54: create_pint_entry stored private_note % (want ''abusivextext'')', v_note; end if;

  select public.create_pint_entry('t54-bound', now(), 'pint', null, false, null, null,
                                  repeat('z', 400)) into v;
  v_note := v->>'private_note';
  if char_length(v_note) <> 280 then
    raise exception 'FAIL t54: private_note length % (want 280)', char_length(v_note); end if;

  -- The note field is `axis: .vertical`, so the user can type paragraph breaks, and the value comes
  -- back to them verbatim in the Art. 15 export — so the breaks must survive. This is the inverse of
  -- the assertion it replaces, which pinned the newline being DELETED: that was the behaviour
  -- LogPintSheet's space-join worked around, and both the workaround and that assertion are now gone.
  -- The tab is still deleted and the blank-line run still collapses to one.
  select public.create_pint_entry('t54-newline', now(), 'pint', null, false, null, null,
                                  'first' || chr(9) || chr(13) || chr(10) ||
                                  'second' || repeat(chr(10), 6) || 'third') into v;
  v_note := v->>'private_note';
  if v_note is distinct from 'first' || chr(10) || 'second' || chr(10) || chr(10) || 'third' then
    raise exception 'FAIL t54: private_note newline handling stored %', quote_literal(v_note); end if;

  raise notice 'PASS t54: create_pint_entry strips control, zero-width and bidi characters from private_note while keeping its line breaks';
end $$;

-- t55: posts.body and post_comments.body keep their line breaks through the real RPCs.
--
-- Both composers are `axis: .vertical`, both render with a bare `Text` (FeedPostCard's `Text(body)`;
-- PostCommentsSheet's `Text(highlightedBody(...))`, whose per-character mask preserves every
-- character it is handed), and both client sanitiser calls already passed `allowNewlines: true`. Only
-- the server disagreed, so every paragraph break typed into a post or a comment was deleted on the
-- way in — and because demo mode stores the client-sanitised string verbatim, the same text kept its
-- layout in demo mode and lost it against a real server.
--
-- Read back through feed_page / post_comments_page rather than the tables, so this asserts what a
-- client actually receives. Ceri acts here: she is well inside post_create's 20/hour.
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000c3';
do $$
declare v jsonb; v_post uuid; v_body text; v_label text; v_payload text; v_expected text;
begin
  -- One payload covering all three behaviours: a tab that must still be deleted, a CRLF that must
  -- become one break, and a five-newline run that must collapse to a single blank line.
  v_payload := 'line one' || chr(9) || chr(13) || chr(10) ||
               'line two' || repeat(chr(10), 5) || 'line three';
  v_expected := 'line one' || chr(10) || 'line two' || chr(10) || chr(10) || 'line three';

  select public.create_post(v_payload, null, null, null) into v;
  v_post := (v->>'post_id')::uuid;
  select body into v_body from public.feed_page(null, null, 20) where post_id = v_post;
  if v_body is distinct from v_expected then
    raise exception 'FAIL t55: create_post stored body % (want %)',
                    quote_literal(v_body), quote_literal(v_expected); end if;

  select public.add_comment(v_post, v_payload, null) into v;
  select body into v_body from public.post_comments_page(v_post, null, null, 30)
   where comment_id = (v->>'comment_id')::uuid;
  if v_body is distinct from v_expected then
    raise exception 'FAIL t55: add_comment stored body % (want %)',
                    quote_literal(v_body), quote_literal(v_expected); end if;

  -- The contrast that proves this is a per-field split and not "controls are no longer stripped":
  -- place_label is single-line (not free-typed — PlacePickerSheet derives it from the chosen map
  -- item — and rendered on one line beside the pub glyph), so its newline is still deleted.
  select public.create_post('body for the label check', null, 'Prague' || chr(10) || 'Old Town', null) into v;
  select place_label into v_label from public.feed_page(null, null, 20)
   where post_id = (v->>'post_id')::uuid;
  if v_label is distinct from 'PragueOld Town' then
    raise exception 'FAIL t55: place_label must stay single-line, got %', quote_literal(v_label); end if;

  raise notice 'PASS t55: posts.body and post_comments.body keep their line breaks; place_label stays single-line';
end $$;

-- ============================ MODERATION QUEUE: review + retention ============================
-- Everything below concerns the two 2026-08-13 operator decisions: public.review_report (the queue
-- was write-only — nothing in the schema ever set reports.status or reports.reviewed_at, so
-- purge_resolved_reports was dead code) and report retention across deletion of the reported
-- account (reported_user_id was `not null on delete cascade`, so a reported user erased every report
-- about them by deleting their account).
--
-- Four throwaway users are created here rather than reusing Alice/Barnaby/Ceri/Dev because one of
-- them gets DELETED, which no earlier fixture can survive. They are added at the very end of the
-- suite, after every count-based assertion above has already run, so they cannot disturb anything.
-- Inserting into auth.users fires handle_new_user(), which creates the profiles + privacy_settings
-- rows (needed for export_my_data in t61).
--
--   Rhian  …f1  reporter, survives
--   Sion   …f2  reported, DELETED in t61
--   Teilo  …f3  reported, survives (control: a different subject must get a different key)
--   Una    …f4  second reporter about Sion, and herself reported — DELETED in t63 (both roles at once)
--   Vaughn …f5  reporter, DELETED in t64 (reporter de-linking + details erasure)
--   Wyn    …f6  reported by Vaughn, DELETED in t64c (making a FULLY de-linked report — no reporter,
--               no subject — which is the row that must not become an immortal orphan)
reset role;
do $$ begin
  insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at)
  values
    ('00000000-0000-0000-0000-000000000000', '00000000-0000-4000-8000-0000000000f1',
     'authenticated', 'authenticated', 'rhian@cheekypint.test', now(), now()),
    ('00000000-0000-0000-0000-000000000000', '00000000-0000-4000-8000-0000000000f2',
     'authenticated', 'authenticated', 'sion@cheekypint.test', now(), now()),
    ('00000000-0000-0000-0000-000000000000', '00000000-0000-4000-8000-0000000000f3',
     'authenticated', 'authenticated', 'teilo@cheekypint.test', now(), now()),
    ('00000000-0000-0000-0000-000000000000', '00000000-0000-4000-8000-0000000000f4',
     'authenticated', 'authenticated', 'una@cheekypint.test', now(), now()),
    ('00000000-0000-0000-0000-000000000000', '00000000-0000-4000-8000-0000000000f5',
     'authenticated', 'authenticated', 'vaughn@cheekypint.test', now(), now()),
    ('00000000-0000-0000-0000-000000000000', '00000000-0000-4000-8000-0000000000f6',
     'authenticated', 'authenticated', 'wyn@cheekypint.test', now(), now())
  on conflict (id) do nothing;

  -- Rhian/Sion and Vaughn/Wyn must be accepted friends so each reporter can see (and therefore
  -- report) the other's post. Inserted directly as the owner: this is fixture plumbing, not the
  -- behaviour under test, and the friend-request RPCs are already exercised at length earlier.
  insert into public.friendships (requester_id, addressee_id, status, responded_at)
  values ('00000000-0000-4000-8000-0000000000f1', '00000000-0000-4000-8000-0000000000f2',
          'accepted', now()),
         ('00000000-0000-4000-8000-0000000000f5', '00000000-0000-4000-8000-0000000000f6',
          'accepted', now())
  on conflict do nothing;

  raise notice 'PASS t56 setup: six throwaway moderation fixtures created (Rhian, Sion, Teilo, Una, Vaughn, Wyn)';
end $$;

-- t56: the pseudonymous subject key is stamped on every report at INSERT time, is stable per
-- subject, differs per subject, and matches public.report_subject_key. This is the value the whole
-- retention decision rests on: if it were not present BEFORE the subject is deleted, t61 would have
-- nothing to retain.
--
-- Also pins the insert-time gate that replaces the old `not null` on reported_user_id: the column is
-- nullable so a report can OUTLIVE its subject, not so a report can be filed about nobody.
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000f1';
do $$
declare
  v jsonb; v_key_sion text; v_key_sion2 text; v_key_teilo text; v_expected text;
  v_state text; v_msg text;
begin
  select public.report_user('00000000-0000-4000-8000-0000000000f2', 'harassment',
                            't56: rhian reports sion') into v;
  select reported_user_key into v_key_sion from public.reports where id = (v->>'report_id')::uuid;

  v_expected := public.report_subject_key('00000000-0000-4000-8000-0000000000f2');
  if v_key_sion is distinct from v_expected then
    raise exception 'FAIL t56: stamped key % does not match report_subject_key %',
                    quote_literal(v_key_sion), quote_literal(v_expected); end if;
  if v_key_sion !~ '^[0-9a-f]{64}$' then
    raise exception 'FAIL t56: key % is not a 64-char hex digest', quote_literal(v_key_sion); end if;

  -- A DIFFERENT subject must get a different key, or the key groups nothing.
  select public.report_user('00000000-0000-4000-8000-0000000000f3', 'other',
                            't56: rhian reports teilo') into v;
  select reported_user_key into v_key_teilo from public.reports where id = (v->>'report_id')::uuid;
  if v_key_teilo = v_key_sion then
    raise exception 'FAIL t56: two different subjects share the key %', quote_literal(v_key_sion); end if;

  -- The SAME subject must get the same key even from a different reporter, or retained reports
  -- about one former account cannot be grouped.
  perform set_config('app.uid', '00000000-0000-4000-8000-0000000000f4', false);
  select public.report_user('00000000-0000-4000-8000-0000000000f2', 'inappropriate_text',
                            't56: una reports sion') into v;
  select reported_user_key into v_key_sion2 from public.reports where id = (v->>'report_id')::uuid;
  if v_key_sion2 is distinct from v_key_sion then
    raise exception 'FAIL t56: same subject got keys % and % from two reporters',
                    quote_literal(v_key_sion), quote_literal(v_key_sion2); end if;

  -- A brand-new report must still name a live account on BOTH sides. Asserted on the exact messages,
  -- not merely "some error": a NOT NULL violation on either key column would also be "some error" and
  -- would mean the guard itself had been deleted.
  reset role;
  v_state := 'NO ERROR'; v_msg := null;
  begin
    insert into public.reports (reporter_id, reported_user_id, category)
    values ('00000000-0000-4000-8000-0000000000f1', null, 'other');
  exception when others then v_state := sqlstate; v_msg := sqlerrm;
  end;
  if v_state is distinct from '23502' then
    raise exception 'FAIL t56: subject-less insert gave sqlstate % (want 23502)', v_state; end if;
  if v_msg is distinct from 'A report must name the account it is about' then
    raise exception 'FAIL t56: subject-less insert message % (want the explicit guard)', quote_literal(v_msg); end if;

  v_state := 'NO ERROR'; v_msg := null;
  begin
    insert into public.reports (reporter_id, reported_user_id, category)
    values (null, '00000000-0000-4000-8000-0000000000f1', 'other');
  exception when others then v_state := sqlstate; v_msg := sqlerrm;
  end;
  if v_state is distinct from '23502' then
    raise exception 'FAIL t56: reporter-less insert gave sqlstate % (want 23502)', v_state; end if;
  if v_msg is distinct from 'A report must name the account that filed it' then
    raise exception 'FAIL t56: reporter-less insert message % (want the explicit guard)', quote_literal(v_msg); end if;

  raise notice 'PASS t56: reported_user_key is stamped at insert, stable per subject, distinct across subjects; a new report must still name an account on both sides';
end $$;

-- t56b: the REPORTER key, and the namespace decision that keeps the two roles apart.
--
-- The last two assertions are the ones that matter and are easy to lose by omission: the reporter key
-- and the subject key for the SAME account must be DIFFERENT values. If they shared a namespace, any
-- two rows could be joined reporter-to-subject to learn "the person who filed A is the person B is
-- about" — across the whole retained corpus, with no account id in hand — a re-identification path
-- across a table whose entire purpose after de-linking is to hold no live reference to a person.
-- Nothing behavioural anywhere else in this suite would notice the two namespaces collapsing into one.
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000f5';
do $$
declare v jsonb; v_key_v text; v_key_v2 text; v_key_r text; begin
  select public.report_user('00000000-0000-4000-8000-0000000000f3', 'other',
                            't56b: vaughn reports teilo') into v;
  select reporter_key into v_key_v from public.reports where id = (v->>'report_id')::uuid;

  if v_key_v is distinct from public.report_reporter_key('00000000-0000-4000-8000-0000000000f5') then
    raise exception 'FAIL t56b: stamped reporter_key % does not match report_reporter_key %',
      quote_literal(v_key_v),
      quote_literal(public.report_reporter_key('00000000-0000-4000-8000-0000000000f5')); end if;
  if v_key_v !~ '^[0-9a-f]{64}$' then
    raise exception 'FAIL t56b: reporter_key % is not a 64-char hex digest', quote_literal(v_key_v); end if;

  -- Stable across the same reporter's other reports.
  select public.report_user('00000000-0000-4000-8000-0000000000f3', 'harassment',
                            't56b: vaughn reports teilo again') into v;
  select reporter_key into v_key_v2 from public.reports where id = (v->>'report_id')::uuid;
  if v_key_v2 is distinct from v_key_v then
    raise exception 'FAIL t56b: one reporter got two keys, % and %',
      quote_literal(v_key_v), quote_literal(v_key_v2); end if;

  -- Distinct across reporters.
  perform set_config('app.uid', '00000000-0000-4000-8000-0000000000f1', false);
  select public.report_user('00000000-0000-4000-8000-0000000000f3', 'other',
                            't56b: rhian reports teilo for the reporter-key check') into v;
  select reporter_key into v_key_r from public.reports where id = (v->>'report_id')::uuid;
  if v_key_r = v_key_v then
    raise exception 'FAIL t56b: two different reporters share the key %', quote_literal(v_key_v); end if;

  -- THE NAMESPACE DECISION: same account, two roles, two different keys.
  if public.report_reporter_key('00000000-0000-4000-8000-0000000000f5')
     = public.report_subject_key('00000000-0000-4000-8000-0000000000f5') then
    raise exception 'FAIL t56b: reporter and subject keys collide for one account — the two roles could then be joined across every de-linked row'; end if;

  -- ...and no such collision exists in the STORED data either, not merely in the functions. Vaughn is
  -- both a reporter (above) and, in t63/t64, a party whose rows persist; Una is a reporter who is
  -- also reported, so this join has real rows on both sides to find a collision in.
  reset role;
  if exists (
    select 1 from public.reports a join public.reports b on a.reporter_key = b.reported_user_key
  ) then
    raise exception 'FAIL t56b: a stored reporter_key equals a stored reported_user_key — cross-role join is possible'; end if;

  raise notice 'PASS t56b: reporter_key is stamped at insert, stable per reporter, distinct across reporters, and in a SEPARATE namespace from the subject key so the two roles cannot be joined';
end $$;

-- t57: review_report transitions the report and gets reviewed_at right.
--
-- reviewed_at is the retention clock's zero point, so each of these four properties changes how long
-- a report is kept:
--   * 'reviewing' must NOT stamp it (the review has started, not concluded) — stamping there would
--     start the 18-month clock at triage time and destroy the report EARLY.
--   * 'actioned'/'dismissed' must stamp it, or purge_resolved_reports can never match the row.
--   * re-running the same outcome must NOT re-stamp it, or a second click restarts the clock.
--   * going back to 'reviewing' must CLEAR it, or a resolved-then-reopened report keeps a
--     conclusion time it no longer has (and violates report_reviewed_at_matches_status).
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000f1';
do $$
declare
  v jsonb; v_id uuid; v_status public.report_status; v_reviewed timestamptz; v_first timestamptz;
begin
  select public.report_user('00000000-0000-4000-8000-0000000000f3', 'impersonation',
                            't57: report to be reviewed') into v;
  v_id := (v->>'report_id')::uuid;
  if (v->>'status') is distinct from 'open' then
    raise exception 'FAIL t57: a new report is % (want open)', v->>'status'; end if;

  reset role;

  -- reviewing: status moves, reviewed_at stays NULL.
  select public.review_report(v_id, 'reviewing') into v;
  if (v->>'status') is distinct from 'reviewing' then
    raise exception 'FAIL t57: review_report returned status %', v->>'status'; end if;
  if (v->>'previous_status') is distinct from 'open' then
    raise exception 'FAIL t57: previous_status % (want open)', v->>'previous_status'; end if;
  select status, reviewed_at into v_status, v_reviewed from public.reports where id = v_id;
  if v_status is distinct from 'reviewing' then
    raise exception 'FAIL t57: stored status % (want reviewing)', v_status; end if;
  if v_reviewed is not null then
    raise exception 'FAIL t57: reviewing stamped reviewed_at = % (must stay NULL: it is the retention clock)', v_reviewed; end if;

  -- actioned: reviewed_at is stamped.
  select public.review_report(v_id, 'actioned') into v;
  if (v->>'reviewed_at') is null then
    raise exception 'FAIL t57: actioned returned a null reviewed_at'; end if;
  select status, reviewed_at into v_status, v_first from public.reports where id = v_id;
  if v_status is distinct from 'actioned' then
    raise exception 'FAIL t57: stored status % (want actioned)', v_status; end if;
  if v_first is null then
    raise exception 'FAIL t57: actioned did not stamp reviewed_at — purge_resolved_reports can never match this row'; end if;

  -- Re-running the same outcome must not restart the clock.
  --
  -- Asserted against a reviewed_at that has been deliberately AGED first. The obvious version of
  -- this assertion — call review_report twice and compare the two timestamps — cannot fail:
  -- `now()` is the TRANSACTION timestamp and this whole do-block is one transaction, so a
  -- re-stamping mutation writes the identical value and pg_sleep() changes nothing. Confirmed by
  -- mutation testing: the first draft of this check stayed green with the idempotence branch of
  -- review_report deleted outright.
  update public.reports set reviewed_at = now() - interval '5 months' where id = v_id;
  select reviewed_at into v_first from public.reports where id = v_id;
  perform public.review_report(v_id, 'actioned');
  select reviewed_at into v_reviewed from public.reports where id = v_id;
  if v_reviewed is distinct from v_first then
    raise exception 'FAIL t57: re-running actioned moved reviewed_at from % to % (restarted the retention clock)',
                    v_first, v_reviewed; end if;

  -- Re-opening the review clears the conclusion time.
  perform public.review_report(v_id, 'reviewing');
  select status, reviewed_at into v_status, v_reviewed from public.reports where id = v_id;
  if v_status is distinct from 'reviewing' or v_reviewed is not null then
    raise exception 'FAIL t57: re-opened report is (%, %) (want reviewing, NULL)', v_status, v_reviewed; end if;

  -- Changing the outcome IS a new conclusion, so it does re-stamp.
  select public.review_report(v_id, 'dismissed') into v;
  select status, reviewed_at into v_status, v_reviewed from public.reports where id = v_id;
  if v_status is distinct from 'dismissed' or v_reviewed is null then
    raise exception 'FAIL t57: dismissed report is (%, %) (want dismissed, a timestamp)', v_status, v_reviewed; end if;

  raise notice 'PASS t57: review_report transitions status; reviewing leaves reviewed_at NULL, outcomes stamp it, a repeat outcome does not restart the clock, and re-opening clears it';
end $$;

-- t57b: report_reviewed_at_matches_status makes the dead-purge state UNREPRESENTABLE.
--
-- This is the constraint that stops the queue silently returning to how it was: a resolved report
-- with a NULL reviewed_at is invisible to purge_resolved_reports and therefore immortal. The operator
-- works in the Supabase dashboard SQL editor as the table owner, where nothing prevents a hand-typed
-- `update reports set status = 'actioned'` — except this. Both directions are asserted, since the
-- constraint is an equivalence: an outcome without a timestamp, and a timestamp without an outcome.
--
-- Added after mutation testing showed that replacing the whole constraint with `check (true)` left
-- the suite green.
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000f1';
do $$
declare v jsonb; v_id uuid; v_state text; begin
  select public.report_user('00000000-0000-4000-8000-0000000000f3', 'other',
                            't57b: report for the constraint checks') into v;
  v_id := (v->>'report_id')::uuid;
  reset role;

  v_state := 'NO ERROR';
  begin update public.reports set status = 'actioned' where id = v_id;
  exception when others then v_state := sqlstate; end;
  if v_state is distinct from '23514' then
    raise exception 'FAIL t57b: resolving a report without stamping reviewed_at gave sqlstate % (want 23514) — such a row is immortal, because purge_resolved_reports needs reviewed_at', v_state; end if;

  v_state := 'NO ERROR';
  begin update public.reports set reviewed_at = now() where id = v_id;
  exception when others then v_state := sqlstate; end;
  if v_state is distinct from '23514' then
    raise exception 'FAIL t57b: stamping reviewed_at on an unresolved report gave sqlstate % (want 23514)', v_state; end if;

  -- ...and the row is untouched, so neither attempt half-applied.
  if (select status from public.reports where id = v_id) is distinct from 'open'
     or (select reviewed_at from public.reports where id = v_id) is not null then
    raise exception 'FAIL t57b: a rejected manual update still changed the row'; end if;

  raise notice 'PASS t57b: a resolved report without reviewed_at (and vice versa) is rejected by the table itself, so a hand-typed dashboard UPDATE cannot recreate the unpurgeable state';
end $$;

-- t58: review_report's rejections, asserted on the exact SQLSTATE **and** the exact message.
--
-- SQLSTATE alone is not enough here: 'open' and a nonexistent id would both be "some exception" to a
-- bare handler, and both guards raise from the same function, so matching only 22023 would let the
-- unknown-id guard stand in for the open guard. `v_state := 'NO ERROR'` before each attempt means a
-- silently SUCCESSFUL call fails the assertion too — there is no handler that can swallow a pass.
reset role;
do $$
declare
  v jsonb; v_id uuid; v_state text; v_msg text; v_status public.report_status;
begin
  set role authenticated;
  perform set_config('app.uid', '00000000-0000-4000-8000-0000000000f1', false);
  select public.report_user('00000000-0000-4000-8000-0000000000f3', 'other',
                            't58: report for the rejection checks') into v;
  v_id := (v->>'report_id')::uuid;
  reset role;

  -- 'open' is the initial state, not a review outcome.
  v_state := 'NO ERROR'; v_msg := null;
  begin perform public.review_report(v_id, 'open');
  exception when others then v_state := sqlstate; v_msg := sqlerrm; end;
  if v_state is distinct from '22023' then
    raise exception 'FAIL t58: review_report(_, open) gave sqlstate % (want 22023)', v_state; end if;
  if v_msg is distinct from 'review_report: open is a report''s initial state, not a review outcome' then
    raise exception 'FAIL t58: review_report(_, open) message % (want the open-specific guard)', quote_literal(v_msg); end if;

  -- A NULL target status is rejected on its own message rather than reaching the UPDATE and dying on
  -- the column's NOT NULL.
  v_state := 'NO ERROR'; v_msg := null;
  begin perform public.review_report(v_id, null);
  exception when others then v_state := sqlstate; v_msg := sqlerrm; end;
  if v_state is distinct from '22023' then
    raise exception 'FAIL t58: review_report(_, null) gave sqlstate % (want 22023)', v_state; end if;
  if v_msg is distinct from 'review_report: a target status is required (reviewing, actioned or dismissed)' then
    raise exception 'FAIL t58: review_report(_, null) message %', quote_literal(v_msg); end if;

  -- Neither rejection may have changed the row.
  select status into v_status from public.reports where id = v_id;
  if v_status is distinct from 'open' then
    raise exception 'FAIL t58: a rejected transition still changed the status to %', v_status; end if;

  -- An unknown id names itself in the message, so the operator can see they pasted the wrong uuid.
  v_state := 'NO ERROR'; v_msg := null;
  begin perform public.review_report('00000000-0000-4000-8000-00000000dead', 'actioned');
  exception when others then v_state := sqlstate; v_msg := sqlerrm; end;
  if v_state is distinct from 'P0002' then
    raise exception 'FAIL t58: review_report(unknown id) gave sqlstate % (want P0002)', v_state; end if;
  if v_msg is distinct from 'review_report: no report with id 00000000-0000-4000-8000-00000000dead' then
    raise exception 'FAIL t58: unknown-id message % (want the id echoed back)', quote_literal(v_msg); end if;

  raise notice 'PASS t58: review_report rejects open, a null status and an unknown id, each on its own message, and changes nothing when it refuses';
end $$;

-- t59: review_report is SERVICE ROLE ONLY, asserted on the FUNCTION privilege.
--
-- Asserting "the call failed" would not prove the revoke: _shim_grants.sql grants `authenticated`
-- table-level DML on every table in public, so a client failing to change a report could equally be
-- RLS doing the work, and a call failing inside the function body for an unrelated reason looks
-- identical to a privilege denial. has_function_privilege reads the grant itself. The 42501 check
-- then confirms the grant is what actually stops the call at runtime, and the direct-UPDATE check
-- confirms there is no way around the function either.
--
-- purge_resolved_reports is included because this change altered its signature (a second interval
-- parameter), and a signature change is exactly how a `revoke` silently stops applying.
reset role;
do $$
declare v_state text;
begin
  if has_function_privilege('authenticated', 'public.review_report(uuid, public.report_status)', 'execute') then
    raise exception 'FAIL t59: authenticated holds EXECUTE on review_report'; end if;
  if has_function_privilege('anon', 'public.review_report(uuid, public.report_status)', 'execute') then
    raise exception 'FAIL t59: anon holds EXECUTE on review_report'; end if;
  if not has_function_privilege('service_role', 'public.review_report(uuid, public.report_status)', 'execute') then
    raise exception 'FAIL t59: service_role cannot EXECUTE review_report — the operator surface is unusable'; end if;

  if has_function_privilege('authenticated', 'public.purge_resolved_reports(interval, interval)', 'execute') then
    raise exception 'FAIL t59: authenticated holds EXECUTE on purge_resolved_reports (did the revoke follow the new signature?)'; end if;
  if has_function_privilege('anon', 'public.purge_resolved_reports(interval, interval)', 'execute') then
    raise exception 'FAIL t59: anon holds EXECUTE on purge_resolved_reports'; end if;

  -- And the grant is what stops the call, at runtime, with the privilege error — not an application
  -- guard that could be edited away.
  set role authenticated;
  perform set_config('app.uid', '00000000-0000-4000-8000-0000000000f1', false);
  v_state := 'NO ERROR';
  begin perform public.review_report('00000000-0000-4000-8000-00000000dead', 'actioned');
  exception when others then v_state := sqlstate; end;
  reset role;
  if v_state is distinct from '42501' then
    raise exception 'FAIL t59: a client calling review_report got sqlstate % (want 42501 insufficient_privilege)', v_state; end if;

  raise notice 'PASS t59: review_report and purge_resolved_reports are service-role only, by function privilege, and a client call is refused with 42501';
end $$;

-- ...and there is no way around the RPC: a reporter holding table DML still cannot transition their
-- own report, because public.reports has a SELECT policy only. `status = 'reviewing'` is used rather
-- than an outcome so that IF the update were permitted it would succeed and be caught here, instead
-- of tripping report_reviewed_at_matches_status and aborting with a confusing message.
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000f1';
do $$ declare v_id uuid; n int; begin
  select id into v_id from public.reports
   where reporter_id = '00000000-0000-4000-8000-0000000000f1' and status = 'open' limit 1;
  if v_id is null then raise exception 'FAIL t59: no open report of Rhian''s to attempt an update on'; end if;
  update public.reports set status = 'reviewing' where id = v_id;
  get diagnostics n = row_count;
  if n <> 0 then
    raise exception 'FAIL t59: a reporter directly transitioned % of their own reports', n; end if;
  raise notice 'PASS t59: a reporter cannot transition a report by direct UPDATE (no UPDATE policy on public.reports)';
end $$;

-- t60: purge_resolved_reports ACTUALLY DELETES a row. This function has never deleted anything in
-- its life — its predicate needed reports.status and reports.reviewed_at, and until review_report
-- existed nothing in the schema ever set either, so the 18-month commitment in
-- docs/legal/DATA_RETENTION_POLICY.md was unenforceable in principle rather than merely unscheduled.
--
-- Asserted on the identity of the specific row, plus two controls, so the assertion cannot pass on a
-- purge that deletes indiscriminately: an actioned report INSIDE the window and an aged report that
-- was never resolved must both survive the same call.
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000f4';
do $$
declare v jsonb; v_aged uuid; v_fresh uuid; v_open uuid; purged int; begin
  select public.report_user('00000000-0000-4000-8000-0000000000f3', 'harassment',
                            't60: actioned and aged past the window') into v;
  v_aged := (v->>'report_id')::uuid;
  select public.report_user('00000000-0000-4000-8000-0000000000f3', 'harassment',
                            't60: actioned but still inside the window') into v;
  v_fresh := (v->>'report_id')::uuid;
  select public.report_user('00000000-0000-4000-8000-0000000000f3', 'harassment',
                            't60: aged but never resolved') into v;
  v_open := (v->>'report_id')::uuid;

  reset role;
  perform public.review_report(v_aged, 'actioned');
  perform public.review_report(v_fresh, 'actioned');

  -- Age the resolved one past the retention window, and the open one past it too (by created_at, so
  -- the resolved-branch predicate has a same-age row it must NOT touch).
  update public.reports set reviewed_at = now() - interval '19 months' where id = v_aged;
  update public.reports set created_at = now() - interval '19 months' where id = v_open;

  select public.purge_resolved_reports(interval '18 months') into purged;
  if purged < 1 then
    raise exception 'FAIL t60: purge_resolved_reports removed % rows (want >= 1) — the queue is still write-only', purged; end if;
  if exists (select 1 from public.reports where id = v_aged) then
    raise exception 'FAIL t60: the actioned, aged report survived the purge'; end if;
  if not exists (select 1 from public.reports where id = v_fresh) then
    raise exception 'FAIL t60: the purge deleted an actioned report still inside the retention window'; end if;
  if not exists (select 1 from public.reports where id = v_open) then
    raise exception 'FAIL t60: the purge deleted an aged report that was never resolved (its subject is still live — that is a triage backlog, not expired retention)'; end if;

  raise notice 'PASS t60: purge_resolved_reports really deletes an actioned report once reviewed_at ages past the window, and spares both an in-window resolved report and an aged unresolved one';
end $$;

-- t61: a report SURVIVES deletion of the account it is about, minimised.
--
-- Deleting the auth user is the real path: the delete-account Edge Function calls
-- admin.auth.admin.deleteUser (supabase/functions/delete-account/index.ts:69), which cascades
-- auth.users -> profiles and from there into every referencing table. Before this change
-- reported_user_id was `not null on delete cascade`, so this delete destroyed the report outright.
--
-- The content-report case is asserted separately and is not redundant: posts.author_id and
-- post_comments.author_id also cascade from profiles, and reports.post_id/comment_id used to cascade
-- from those, so de-linking reported_user_id alone would still have lost every report about a post
-- or comment — the retention decision would have applied to account reports only.
--
-- The reporter_id asymmetry is asserted too, deliberately: it still cascades (the operator decided
-- only about reported_user_id), so a report Sion FILED about Teilo is destroyed by Sion's deletion
-- even though it is about a third party. Pinned here so the asymmetry is visible in a test rather
-- than only in prose.
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000f2';
do $$ declare v jsonb; v_post uuid; begin
  select public.create_post('t61: sion post that gets reported', null, null, null) into v;
  v_post := (v->>'post_id')::uuid;
  perform set_config('app.uid', '00000000-0000-4000-8000-0000000000f1', false);
  perform public.report_post(v_post, 'inappropriate_post_image', 't61: rhian reports sion''s post');
  -- Sion files a report of his own, about a third party, which his deletion will destroy.
  perform set_config('app.uid', '00000000-0000-4000-8000-0000000000f2', false);
  perform public.report_user('00000000-0000-4000-8000-0000000000f3', 'underage_concern',
                             't61: sion reports teilo — filed BY the departing user');
  raise notice 'PASS t61 setup: Sion posts, Rhian reports the post, Sion files a report about Teilo';
end $$;

reset role;
do $$
declare
  v_key text; v_about_subject int; v_content int; v_filed int; v_post_link uuid;
  v_details text; v_category public.report_category; v_created timestamptz; v_created_after timestamptz;
  v_subject uuid;
begin
  v_key := public.report_subject_key('00000000-0000-4000-8000-0000000000f2');

  -- Counted by the pseudonymous key alone, NOT by `post_id is null` — the first draft of this
  -- assertion filtered on that and went red, because a retained CONTENT report has its post link
  -- cleared and so becomes indistinguishable from an account report. That is the accepted limitation
  -- recorded at 20260811000400_feed_reports.sql; the test may not quietly assume otherwise.
  select count(*) into v_about_subject from public.reports where reported_user_key = v_key;
  if v_about_subject < 3 then
    raise exception 'FAIL t61: expected >= 3 reports about Sion before deletion (2 account + 1 content), found %', v_about_subject; end if;

  select details, category, created_at into v_details, v_category, v_created
    from public.reports
   where reported_user_key = v_key and details = 't56: rhian reports sion';

  select count(*) into v_filed from public.reports
   where reporter_id = '00000000-0000-4000-8000-0000000000f2';
  if v_filed < 1 then raise exception 'FAIL t61: Sion filed no reports to test the reporter cascade with'; end if;

  -- The real deletion path.
  delete from auth.users where id = '00000000-0000-4000-8000-0000000000f2';

  if exists (select 1 from public.profiles where id = '00000000-0000-4000-8000-0000000000f2') then
    raise exception 'FAIL t61: Sion''s profile survived the auth.users delete'; end if;

  -- 1. Every report about Sion is still there, de-linked, with its content intact.
  if (select count(*) from public.reports where reported_user_key = v_key)
       is distinct from v_about_subject then
    raise exception 'FAIL t61: reports about Sion were destroyed by his deletion (% of % kept)',
      (select count(*) from public.reports where reported_user_key = v_key), v_about_subject; end if;

  select reported_user_id, details, category, created_at
    into v_subject, v_details, v_category, v_created_after
    from public.reports
   where reported_user_key = v_key and details = 't56: rhian reports sion';
  if v_subject is not null then
    raise exception 'FAIL t61: retained report still points at a person (reported_user_id = %)', v_subject; end if;
  if v_details is distinct from 't56: rhian reports sion' then
    raise exception 'FAIL t61: retained report lost its details (%)', quote_literal(v_details); end if;
  if v_category is distinct from 'harassment' then
    raise exception 'FAIL t61: retained report lost its category (%)', v_category; end if;
  if v_created_after is distinct from v_created then
    raise exception 'FAIL t61: retained report''s created_at moved from % to %', v_created, v_created_after; end if;

  -- 2. The key is unchanged by the deletion — it is the whole point of retaining the row.
  if not exists (select 1 from public.reports where reported_user_key = v_key) then
    raise exception 'FAIL t61: no row carries the former subject''s pseudonymous key after deletion'; end if;

  -- 3. The CONTENT report survived too, with only the dangling post link cleared.
  select count(*) into v_content from public.reports
   where reported_user_key = v_key and details = 't61: rhian reports sion''s post';
  if v_content <> 1 then
    raise exception 'FAIL t61: the report about Sion''s post did not survive his deletion (found % rows) — reports.post_id cascades from posts, which cascade from profiles', v_content; end if;
  select post_id into v_post_link from public.reports
   where reported_user_key = v_key and details = 't61: rhian reports sion''s post';
  if v_post_link is not null then
    raise exception 'FAIL t61: retained content report still points at a deleted post (%)', v_post_link; end if;

  -- 4. Sion was ALSO a reporter, so his deletion exercises the reporter side at the same time. The
  -- report he FILED about Teilo survives, de-linked, with his own free text erased.
  --
  -- Rewritten when reporter_id became `on delete set null`: the previous version asserted
  -- `not exists (… where reporter_id = sion)` and `not exists (… where details = '<his text>')`, and
  -- BOTH of those now pass VACUOUSLY — the first because reporter_id is NULL rather than his id, the
  -- second because the details it looked for is exactly what gets erased. Two green assertions
  -- asserting nothing. They are replaced with identity-based ones: the row is found by the reporter
  -- key, which is the only durable handle on it.
  if not exists (
    select 1 from public.reports
     where reporter_key = public.report_reporter_key('00000000-0000-4000-8000-0000000000f2')
  ) then
    raise exception 'FAIL t61: the report Sion FILED was destroyed by his deletion — reporter_id must de-link, not cascade'; end if;
  if exists (
    select 1 from public.reports
     where reporter_key = public.report_reporter_key('00000000-0000-4000-8000-0000000000f2')
       and reporter_id is not null
  ) then
    raise exception 'FAIL t61: a report Sion filed still points at him'; end if;
  if exists (
    select 1 from public.reports
     where reporter_key = public.report_reporter_key('00000000-0000-4000-8000-0000000000f2')
       and details is not null
  ) then
    raise exception 'FAIL t61: the departing reporter''s free-text details survived his deletion'; end if;
  -- The rest of that row is intact — it still records that a complaint of this category was made
  -- about Teilo on this date, which is the signal the retention exists to keep.
  if not exists (
    select 1 from public.reports
     where reporter_key = public.report_reporter_key('00000000-0000-4000-8000-0000000000f2')
       and reported_user_id = '00000000-0000-4000-8000-0000000000f3'
       and category = 'underage_concern'
  ) then
    raise exception 'FAIL t61: the report Sion filed lost its subject or category along with his details'; end if;

  raise notice 'PASS t61: deleting an account de-links reports on BOTH sides at once — reports about him keep their details, the report he filed keeps its category, subject and dates but loses his free text';
end $$;

-- t61b: report_not_self still constrains, now that BOTH sides are nullable.
--
-- The catalog assertion that used to live here — "the definition must contain `is distinct from`" —
-- has been DELETED, deliberately, and the reasoning is worth keeping because it inverted:
--
--   * While reporter_id was `not null`, `is distinct from` was the safe form and the property had no
--     reachable behaviour, so a catalog check was the only honest test available.
--   * Now that reporter_id is nullable, `is distinct from` is the WRONG form: a row that has lost both
--     parties evaluates `null is distinct from null` = FALSE, and the constraint would block the
--     second de-link, i.e. account deletion would start failing. So the old assertion would now
--     demand the broken form.
--   * And the property is finally behaviourally reachable: t64c deletes both parties of one report,
--     which is exactly the second de-link that `is distinct from` would refuse. A real test replaced
--     the catalog check rather than being added alongside it.
--
-- What is left here is the half that IS reachable independently: the constraint still rejects a
-- self-report. Note that a bare `reporter_id <> reported_user_id` would pass both this assertion and
-- t64c's, because with two non-null ids it is equivalent and with either id NULL it yields NULL
-- (satisfied) — the explicit three-way form is chosen for totality, not for a behavioural difference,
-- and asserting on a form with no behavioural consequence is the kind of tautology this suite avoids.
reset role;
do $$ declare v_state text; begin
  v_state := 'NO ERROR';
  begin
    insert into public.reports (reporter_id, reported_user_id, category)
    values ('00000000-0000-4000-8000-0000000000f1', '00000000-0000-4000-8000-0000000000f1', 'other');
  exception when others then v_state := sqlstate; end;
  if v_state is distinct from '23514' then
    raise exception 'FAIL t61b: a self-report insert gave sqlstate % (want 23514 check_violation)', v_state; end if;

  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.reports'::regclass and conname = 'report_not_self'
  ) then raise exception 'FAIL t61b: report_not_self does not exist'; end if;

  raise notice 'PASS t61b: report_not_self still rejects a self-report with both party columns nullable';
end $$;

-- t61c: a retained report with a NULL subject still exports for its reporter (Art. 15).
--
-- The pre-existing t51 assertions cannot see this case: export_my_data omits reported_user_id
-- entirely, so a retained report and an ordinary one look identical in the output, and t51's fixture
-- subject (Barnaby) is never deleted. Rhian is used because t51 exhausted Alice's data_export rate
-- limit (5/24h) and Rhian has not called it.
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000f1';
do $$ declare v jsonb; v_retained jsonb; begin
  select public.export_my_data() into v;
  if v is null then raise exception 'FAIL t61c: export returned null'; end if;

  select e into v_retained from jsonb_array_elements(v->'reports') e
   where e->>'details' = 't56: rhian reports sion';
  if v_retained is null then
    raise exception 'FAIL t61c: the reporter''s retained report (subject deleted) is missing from their export'; end if;
  if (v_retained->>'reporter_id') is distinct from '00000000-0000-4000-8000-0000000000f1' then
    raise exception 'FAIL t61c: retained report exported with reporter_id %', v_retained->>'reporter_id'; end if;
  if (v_retained->>'category') is distinct from 'harassment' then
    raise exception 'FAIL t61c: retained report exported with category %', v_retained->>'category'; end if;

  -- The subject's identifiers must not reappear here — neither the (now NULL) id nor the pseudonym,
  -- which is an identifier FOR THE ACCUSED PARTY and so falls under the same omission.
  if v_retained ? 'reported_user_id' then
    raise exception 'FAIL t61c: export exposed reported_user_id on a retained report'; end if;
  if v_retained ? 'reported_user_key' then
    raise exception 'FAIL t61c: export exposed reported_user_key — a pseudonym for the accused party'; end if;

  raise notice 'PASS t61c: a retained report whose subject was deleted still exports to its reporter, without the subject''s id or pseudonym';
end $$;

-- t62: retained reports have a FINITE lifetime. Without this branch a report about a departed
-- account that nobody ever triaged is kept forever, which would make the retention decision itself
-- an Art. 5(1)(e) violation rather than a fix. Keyed off created_at because a never-resolved report
-- has no reviewed_at to key off (report_reviewed_at_matches_status guarantees that).
--
-- Three controls, so the branch cannot pass by deleting too much: a retained report still inside its
-- window survives; an aged report whose subject is still LIVE survives (that is a triage backlog, a
-- separate operator decision); and an aged-by-created_at retained report that WAS resolved recently
-- survives, because a resolved report is governed by the reviewed_at clock instead.
reset role;
do $$
declare
  v_old uuid; v_new uuid; v_live uuid; v_resolved uuid; v_key text; purged int;
begin
  v_key := public.report_subject_key('00000000-0000-4000-8000-0000000000f2');

  select id into v_old from public.reports
   where reported_user_key = v_key and details = 't56: rhian reports sion';
  select id into v_new from public.reports
   where reported_user_key = v_key and details = 't56: una reports sion';
  select id into v_resolved from public.reports
   where reported_user_key = v_key and details = 't61: rhian reports sion''s post';
  select id into v_live from public.reports
   where reported_user_id = '00000000-0000-4000-8000-0000000000f3'
     and details = 't60: aged but never resolved';
  if v_old is null or v_new is null or v_resolved is null or v_live is null then
    raise exception 'FAIL t62: fixtures missing (old %, new %, resolved %, live %)', v_old, v_new, v_resolved, v_live; end if;

  -- Age two retained rows past 24 months; leave the third retained row recent.
  update public.reports set created_at = now() - interval '25 months' where id in (v_old, v_resolved);
  perform public.review_report(v_resolved, 'dismissed');   -- recent reviewed_at, ancient created_at

  select public.purge_resolved_reports(interval '18 months', interval '24 months') into purged;
  if purged < 1 then
    raise exception 'FAIL t62: the retained-report branch purged % rows (want >= 1)', purged; end if;
  if exists (select 1 from public.reports where id = v_old) then
    raise exception 'FAIL t62: a retained report 25 months old and never reviewed was kept indefinitely'; end if;
  if not exists (select 1 from public.reports where id = v_new) then
    raise exception 'FAIL t62: the purge deleted a retained report still inside its 24-month window'; end if;
  if not exists (select 1 from public.reports where id = v_live) then
    raise exception 'FAIL t62: the purge deleted an aged unresolved report whose subject is still live'; end if;
  if not exists (select 1 from public.reports where id = v_resolved) then
    raise exception 'FAIL t62: the purge deleted a retained report that was resolved recently — a resolved report is governed by the reviewed_at clock, not created_at'; end if;

  raise notice 'PASS t62: retained reports never reviewed are purged 24 months after created_at, while in-window, live-subject and recently-resolved rows are spared';
end $$;

-- t63: the whole account-deletion sequence still completes for a user who is on BOTH sides of the
-- moderation queue.
--
-- This is the specific hazard of turning a cascade into `set null`: a FK that no longer cascades can
-- BLOCK a delete if anything downstream relied on the cascade to clear the referencing rows. The
-- delete-account Edge Function runs two steps against the database, in this order
-- (supabase/functions/delete-account/index.ts:37,69):
--
--   1. `public.delete_account()` AS the user — anonymise + tear down friendships, blocks, tokens,
--      sessions, diary. It never touches public.reports, so reports still reference the departing
--      user when it returns. Nothing in this suite exercised this RPC at all before now.
--   2. `auth.admin.deleteUser` — deletes auth.users, cascading to profiles and from there into
--      reports via BOTH of its FKs at once: reporter_id (cascade, deletes the row) and
--      reported_user_id (set null, keeps it).
--
-- Una is used because she is on both sides: she filed reports in t56/t60 and Rhian reports her here.
-- The two FK actions therefore fire against her in the same statement, which is the case most likely
-- to deadlock, conflict, or trip a constraint if the change is wrong.
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000f1';
do $$ begin
  perform public.report_user('00000000-0000-4000-8000-0000000000f4', 'inappropriate_text',
                             't63: rhian reports una, who is also a reporter');
  raise notice 'PASS t63 setup: Una is now both a reporter and a reported user';
end $$;

reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000f4';
do $$
declare v_filed int; v_about int; v_key text; v_rkey text; v_subject uuid; begin
  v_key  := public.report_subject_key('00000000-0000-4000-8000-0000000000f4');
  v_rkey := public.report_reporter_key('00000000-0000-4000-8000-0000000000f4');

  reset role;
  select count(*) into v_filed from public.reports
   where reporter_id = '00000000-0000-4000-8000-0000000000f4';
  select count(*) into v_about from public.reports where reported_user_key = v_key;
  if v_filed < 1 or v_about < 1 then
    raise exception 'FAIL t63: Una must be on both sides (filed %, about %)', v_filed, v_about; end if;

  -- Step 1, as the user. Must not raise: a report referencing her is not her data to tear down.
  set role authenticated;
  perform set_config('app.uid', '00000000-0000-4000-8000-0000000000f4', false);
  perform public.delete_account();
  reset role;

  if (select deleted_at from public.profiles where id = '00000000-0000-4000-8000-0000000000f4') is null then
    raise exception 'FAIL t63: delete_account did not mark the profile deleted'; end if;
  -- ...and it left the moderation queue alone, as it always did.
  if (select count(*) from public.reports where reported_user_key = v_key) is distinct from v_about then
    raise exception 'FAIL t63: delete_account changed the reports about the caller'; end if;

  -- Step 2: the auth-user deletion, where both FK actions fire against her at once.
  delete from auth.users where id = '00000000-0000-4000-8000-0000000000f4';

  if exists (select 1 from public.profiles where id = '00000000-0000-4000-8000-0000000000f4') then
    raise exception 'FAIL t63: the profile survived the auth.users delete'; end if;

  -- Both FK actions fired against her in that one statement, and both sides must have retained.
  -- Rewritten when reporter_id became `on delete set null`: the previous version asserted
  -- `not exists (… where reporter_id = una)`, which now passes VACUOUSLY — reporter_id is NULL rather
  -- than her id, so the predicate matches nothing whether the rows survived or not.
  if (select count(*) from public.reports where reporter_key = v_rkey) is distinct from v_filed then
    raise exception 'FAIL t63: % of % reports Una FILED survived',
      (select count(*) from public.reports where reporter_key = v_rkey), v_filed; end if;
  if exists (select 1 from public.reports where reporter_key = v_rkey and reporter_id is not null) then
    raise exception 'FAIL t63: a report Una filed still points at her'; end if;
  if exists (select 1 from public.reports where reporter_key = v_rkey and details is not null) then
    raise exception 'FAIL t63: Una''s own free text survived her deletion'; end if;

  if (select count(*) from public.reports where reported_user_key = v_key) is distinct from v_about then
    raise exception 'FAIL t63: reports about Una were destroyed (% of % kept)',
      (select count(*) from public.reports where reported_user_key = v_key), v_about; end if;
  select reported_user_id into v_subject from public.reports where reported_user_key = v_key limit 1;
  if v_subject is not null then
    raise exception 'FAIL t63: a retained report about Una still points at her (%)', v_subject; end if;
  -- The asymmetry, on one account, in one statement: the report ABOUT her keeps the text ANOTHER
  -- person wrote (that is the Art. 17(3)(e) evidence), while the report SHE filed loses hers.
  if not exists (
    select 1 from public.reports where reported_user_key = v_key and details is not null
  ) then
    raise exception 'FAIL t63: a report about Una lost the details its own reporter wrote — only the DEPARTING party''s text should be erased'; end if;

  raise notice 'PASS t63: delete_account() then the auth.users delete both succeed for a user on both sides of the queue — reports she filed are retained minus her free text, reports about her are retained WITH their reporter''s text';
end $$;

-- ============================ REPORTER DE-LINKING (operator decision 2026-08-13b) ============================
-- Vaughn files two reports — one about Teilo's ACCOUNT (details is the only evidence it will ever
-- have) and one about Wyn's POST (where post_id still points at the actual evidence). Both keep their
-- free text until he leaves.
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000f6';
do $$ declare v jsonb; v_post uuid; begin
  select public.create_post('t64: wyn post that vaughn reports', null, null, null) into v;
  v_post := (v->>'post_id')::uuid;
  perform set_config('app.uid', '00000000-0000-4000-8000-0000000000f5', false);
  perform public.report_post(v_post, 'inappropriate_post_image',
                             't64: vaughn reports wyn''s post — content report, evidence is the post');
  perform public.report_user('00000000-0000-4000-8000-0000000000f3', 'harassment',
                             't64: vaughn reports teilo''s account — free text is the ONLY evidence');
  raise notice 'PASS t64 setup: Vaughn files one content report and one account report, both with details';
end $$;

-- t64a: the CHECK, not the trigger, is what guarantees the erasure.
--
-- The comment on reports_erase_reporter_details claims that if the trigger stops firing, the FK's own
-- set-null violates report_details_erased_with_reporter and the whole account deletion ABORTS — rather
-- than silently leaving a de-linked row that kept the departed reporter's prose. That claim is tested
-- here by actually disabling the trigger and attempting a real account deletion.
--
-- This is the one place the suite disables a trigger. It is the only way to reach the state the
-- constraint exists for: with the trigger working, the constraint can never be violated, so a test of
-- the constraint alone would be unfalsifiable. The failed delete is caught inside a plpgsql
-- subtransaction, so it rolls back, and the trigger is re-enabled before anything else runs.
reset role;
do $$
declare v_state text; v_msg text; v_details_before int; begin
  select count(*) into v_details_before from public.reports
   where reporter_id = '00000000-0000-4000-8000-0000000000f5' and details is not null;
  if v_details_before < 2 then
    raise exception 'FAIL t64a: Vaughn should have 2+ reports with details, has %', v_details_before; end if;

  alter table public.reports disable trigger reports_erase_reporter_details;

  v_state := 'NO ERROR'; v_msg := null;
  begin
    delete from auth.users where id = '00000000-0000-4000-8000-0000000000f5';
  exception when others then v_state := sqlstate; v_msg := sqlerrm;
  end;

  alter table public.reports enable trigger reports_erase_reporter_details;

  if v_state is distinct from '23514' then
    raise exception 'FAIL t64a: with the erasing trigger disabled, deleting the reporter gave sqlstate % (want 23514) — the erasure is only enforced by a trigger, so it can fail SILENTLY', v_state; end if;
  if v_msg not like '%report_details_erased_with_reporter%' then
    raise exception 'FAIL t64a: the abort did not name report_details_erased_with_reporter: %', quote_literal(v_msg); end if;

  -- Aborted, therefore nothing half-happened: the account is still there and every detail is intact.
  if not exists (select 1 from public.profiles where id = '00000000-0000-4000-8000-0000000000f5') then
    raise exception 'FAIL t64a: the account was deleted even though the transaction aborted'; end if;
  if (select count(*) from public.reports
       where reporter_id = '00000000-0000-4000-8000-0000000000f5' and details is not null)
     is distinct from v_details_before then
    raise exception 'FAIL t64a: a half-erased report survived an aborted deletion'; end if;

  raise notice 'PASS t64a: with the erasing trigger disabled, deleting a reporter ABORTS on report_details_erased_with_reporter and leaves nothing half-erased — the constraint is the guarantee, the trigger only satisfies it';
end $$;

-- t64: deleting the reporter erases their prose and keeps everything else.
reset role;
do $$
declare
  v_key text; v_filed int; v_content_post uuid; v_others int;
begin
  v_key := public.report_reporter_key('00000000-0000-4000-8000-0000000000f5');
  select count(*) into v_filed from public.reports
   where reporter_id = '00000000-0000-4000-8000-0000000000f5';
  select post_id into v_content_post from public.reports
   where reporter_id = '00000000-0000-4000-8000-0000000000f5' and post_id is not null;
  if v_filed < 3 or v_content_post is null then
    raise exception 'FAIL t64: fixtures missing (filed %, content post %)', v_filed, v_content_post; end if;

  -- Details written by OTHER reporters about the same subject, which must NOT be touched.
  select count(*) into v_others from public.reports
   where reported_user_id = '00000000-0000-4000-8000-0000000000f3'
     and reporter_id = '00000000-0000-4000-8000-0000000000f1' and details is not null;
  if v_others < 1 then
    raise exception 'FAIL t64: need at least one other reporter''s detailed report about Teilo as a control'; end if;

  delete from auth.users where id = '00000000-0000-4000-8000-0000000000f5';

  if exists (select 1 from public.profiles where id = '00000000-0000-4000-8000-0000000000f5') then
    raise exception 'FAIL t64: Vaughn''s profile survived the auth.users delete'; end if;

  -- 1. Every report he filed survives, found by the durable handle.
  if (select count(*) from public.reports where reporter_key = v_key) is distinct from v_filed then
    raise exception 'FAIL t64: % of % reports Vaughn filed survived his deletion',
      (select count(*) from public.reports where reporter_key = v_key), v_filed; end if;

  -- 2. De-linked, and his prose is gone from all of them.
  if exists (select 1 from public.reports where reporter_key = v_key and reporter_id is not null) then
    raise exception 'FAIL t64: a report Vaughn filed still points at him'; end if;
  if exists (select 1 from public.reports where reporter_key = v_key and details is not null) then
    raise exception 'FAIL t64: the departing reporter''s details survived: %',
      (select quote_literal(details) from public.reports where reporter_key = v_key and details is not null limit 1); end if;

  -- 3. The signal is intact: category, dates, the still-live subject, and the content link.
  if not exists (
    select 1 from public.reports
     where reporter_key = v_key and reported_user_id = '00000000-0000-4000-8000-0000000000f3'
       and category = 'harassment' and created_at is not null
  ) then raise exception 'FAIL t64: the account report lost its subject, category or date with its details'; end if;
  if not exists (
    select 1 from public.reports where reporter_key = v_key and post_id = v_content_post
  ) then
    raise exception 'FAIL t64: the content report lost its post link — for a content report the post IS the evidence that replaces the erased text'; end if;

  -- 4. No over-erasure: another reporter's text about the same subject is untouched.
  if (select count(*) from public.reports
       where reported_user_id = '00000000-0000-4000-8000-0000000000f3'
         and reporter_id = '00000000-0000-4000-8000-0000000000f1' and details is not null)
     is distinct from v_others then
    raise exception 'FAIL t64: erasing one reporter''s details also erased another reporter''s'; end if;

  raise notice 'PASS t64: deleting a reporter de-links their reports and erases their free text, while keeping category, dates, subject and content links — and leaves other reporters'' text alone';
end $$;

-- t64b: a de-linked report is invisible to every client.
--
-- reports_select_own is `reporter_id = auth.uid()`, which yields NULL — not true — once reporter_id is
-- NULL, so a report with no living reporter is readable by nobody through the app. Asserted rather
-- than assumed, because the two plausible "tidier" spellings of that policy both leak: `is not
-- distinct from` hands every de-linked row to any caller whose auth.uid() is NULL, and an added
-- `or reporter_id is null` branch hands them to EVERY authenticated user.
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000f1';
do $$ declare v_visible int; v_own int; begin
  select count(*) into v_visible from public.reports where reporter_id is null;
  if v_visible <> 0 then
    raise exception 'FAIL t64b: an authenticated caller can see % de-linked reports', v_visible; end if;

  -- ...and the policy still works for rows that DO have a reporter, so this is not "the table went
  -- dark" passing for "orphans are hidden".
  select count(*) into v_own from public.reports;
  if v_own < 1 then
    raise exception 'FAIL t64b: the caller can no longer see any of their own reports either'; end if;
  if exists (select 1 from public.reports
              where reporter_id is distinct from '00000000-0000-4000-8000-0000000000f1') then
    raise exception 'FAIL t64b: the caller can see a report they did not file'; end if;

  raise notice 'PASS t64b: a de-linked report is invisible to every client, while the reporter still sees their own live reports';
end $$;

-- t64c: a FULLY de-linked report — no reporter, no subject — is still reachable by the purge.
--
-- This row is the one with no living party to trigger any other cleanup, so if the purge missed it, it
-- would be immortal. Deleting Wyn is also the SECOND de-link of a report whose reporter (Vaughn) has
-- already gone, which is the behavioural proof for report_not_self's NULL-safe form: with the previous
-- `is distinct from` spelling, `null is distinct from null` = FALSE and this delete would abort.
reset role;
do $$
declare
  v_rkey text; v_skey text; v_full uuid; v_recent uuid; purged int; v_reporter uuid; v_subject uuid;
begin
  v_rkey := public.report_reporter_key('00000000-0000-4000-8000-0000000000f5');
  v_skey := public.report_subject_key('00000000-0000-4000-8000-0000000000f6');

  select id into v_full from public.reports
   where reporter_key = v_rkey and reported_user_key = v_skey;
  if v_full is null then
    raise exception 'FAIL t64c: no report by Vaughn about Wyn to fully de-link'; end if;

  -- The second de-link. If report_not_self were `is distinct from`, this raises 23514 and the suite
  -- fails here rather than at an assertion.
  delete from auth.users where id = '00000000-0000-4000-8000-0000000000f6';

  select reporter_id, reported_user_id into v_reporter, v_subject
    from public.reports where id = v_full;
  if v_reporter is not null or v_subject is not null then
    raise exception 'FAIL t64c: the report is not fully de-linked (reporter %, subject %)', v_reporter, v_subject; end if;
  if not exists (select 1 from public.reports where id = v_full) then
    raise exception 'FAIL t64c: the fully de-linked report was destroyed rather than retained'; end if;

  -- A second fully de-linked row, left recent, as the in-window control.
  select id into v_recent from public.reports
   where reporter_key = v_rkey and id <> v_full
     and reporter_id is null and reported_user_id is null limit 1;

  update public.reports set created_at = now() - interval '25 months' where id = v_full;

  select public.purge_resolved_reports(interval '18 months', interval '24 months') into purged;
  if purged < 1 then
    raise exception 'FAIL t64c: the purge removed % rows — a report with neither party left is an immortal orphan', purged; end if;
  if exists (select 1 from public.reports where id = v_full) then
    raise exception 'FAIL t64c: a fully de-linked report 25 months old survived the purge'; end if;
  if v_recent is not null and not exists (select 1 from public.reports where id = v_recent) then
    raise exception 'FAIL t64c: the purge also took a fully de-linked report still inside its window'; end if;

  raise notice 'PASS t64c: a report with neither party left is retained, de-linked on both sides, and purged 24 months after filing — not immortal, and the second de-link is not blocked by report_not_self';
end $$;

reset role;
\echo '-------------------------------------------'
\echo 'ALL RLS/RPC CHECKS PASSED'
\echo '-------------------------------------------'
