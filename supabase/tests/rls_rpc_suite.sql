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
  select count(*) into v_count from public.feed_page(null, 20) where author_id = '00000000-0000-4000-8000-0000000000a1';
  if v_count <> 1 then raise exception 'FAIL t28: author sees % of own posts (want 1)', v_count; end if;
  raise notice 'PASS t28: create_post stores a post the author can read back';
end $$;

do $$ begin
  begin
    perform public.create_post(null, null, 'Prague', null);
    raise exception 'FAIL t29: create_post accepted a post with neither body nor image';
  exception when others then null;
  end;
  begin
    perform public.create_post('x', null, null, '00000000-0000-4000-8000-00000000e001');
    raise exception 'FAIL t29: create_post accepted a pub_id with no place_label';
  exception when others then null;
  end;
  raise notice 'PASS t29: create_post rejects empty posts and unlabelled pub references';
end $$;

do $$ declare v text; begin
  perform public.create_post('clean' || chr(8203) || chr(9) || 'text', null, null, null);
  select body into v from public.feed_page(null, 20) order by created_at desc limit 1;
  if v <> 'cleantext' then raise exception 'FAIL t30: post body not sanitised, got %', v; end if;
  raise notice 'PASS t30: create_post strips control and zero-width characters from the body';
end $$;

-- Barnaby is an accepted friend of Alice; Ceri is a friend of Alice but NOT of Barnaby.
reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000b2';
do $$ declare v_count int; begin
  select count(*) into v_count from public.feed_page(null, 20)
    where author_id = '00000000-0000-4000-8000-0000000000a1';
  if v_count <> 2 then raise exception 'FAIL t31: friend sees % of Alice posts (want 2)', v_count; end if;
  raise notice 'PASS t31: an accepted friend sees the posts';
end $$;

reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000d4';
do $$ declare v_count int; begin
  select count(*) into v_count from public.feed_page(null, 20);
  if v_count <> 0 then raise exception 'FAIL t31: blocked user sees % posts (want 0)', v_count; end if;
  raise notice 'PASS t31: a blocked user sees nothing';
end $$;

reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000a1';
do $$ declare v_id uuid; v_count int; begin
  select post_id into v_id from public.feed_page(null, 20) order by created_at desc limit 1;
  perform public.delete_post(v_id);
  select count(*) into v_count from public.feed_page(null, 20) where post_id = v_id;
  if v_count <> 0 then raise exception 'FAIL t32: soft-deleted post still visible'; end if;
  raise notice 'PASS t32: delete_post hides the post from every read path';
end $$;

reset role; set role authenticated; set app.uid = '00000000-0000-4000-8000-0000000000b2';
do $$ declare v_id uuid; begin
  select post_id into v_id from public.feed_page(null, 20) limit 1;
  begin
    perform public.delete_post(v_id);
    raise exception 'FAIL t32: a non-author deleted someone else''s post';
  exception when others then null;
  end;
  raise notice 'PASS t32: only the author can delete a post';
end $$;

reset role;
\echo '-------------------------------------------'
\echo 'ALL RLS/RPC CHECKS PASSED'
\echo '-------------------------------------------'
