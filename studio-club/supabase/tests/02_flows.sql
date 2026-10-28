-- What members and staff actually do, start to finish.
\set ON_ERROR_STOP on
\set QUIET on
set client_min_messages = notice;
begin;

select tests.staff('Front');
select tests.member('Ava'); select tests.member('Ben'); select tests.member('Cleo'); select tests.member('Dan'); select tests.member('Eli');

-- ══ profiles ═════════════════════════════════════════════════════════════
do $$
declare r jsonb; n1 int; n2 int; s jsonb;
begin
  insert into auth.users (email) values ('newbie@example.test');
  perform tests.as_member('newbie');
  s := public.my_stats();
  perform tests.eq('before setup, my_stats says there is no profile', s ->> 'has_profile', 'false');
  perform tests.eq('before setup, check-in asks for a profile', public.check_in('ABCDEF') ->> 'status', 'no_profile');
  perform tests.eq('before setup, the wall is empty', (select count(*)::int from public.wall_feed()), 0);
  perform tests.eq('before setup, posting asks for a profile', public.wall_post(gen_random_uuid(), 'hi') ->> 'status', 'no_profile');

  perform tests.eq('empty name is refused', public.upsert_my_profile('   ', null, 'sage') ->> 'status', 'invalid_name');
  perform tests.eq('31-character name is refused', public.upsert_my_profile(repeat('x', 31), null, 'sage') ->> 'status', 'invalid_name');
  perform tests.eq('unknown avatar is refused', public.upsert_my_profile('Nia', null, 'neon') ->> 'status', 'invalid_avatar');
  perform tests.eq('a good profile is saved', public.upsert_my_profile('  Nia  ', '  Yoga Flow ', 'clay') ->> 'status', 'ok');
  s := public.my_stats();
  perform tests.eq('name is trimmed', s #>> '{profile,display_name}', 'Nia');
  perform tests.eq('favourite class is trimmed', s #>> '{profile,favorite_class}', 'Yoga Flow');
  perform tests.ok('member numbers start at 1001 or later', (s #>> '{profile,member_number}')::int >= 1001);
  n1 := (s #>> '{profile,member_number}')::int;
  perform public.upsert_my_profile('Nia B', null, 'gold');
  n2 := (public.my_stats() #>> '{profile,member_number}')::int;
  perform tests.eq('editing the profile never changes the member number', n2, n1);
  perform tests.eq('editing the profile changes the name', public.my_stats() #>> '{profile,display_name}', 'Nia B');
  perform tests.logout();
end $$;

-- ══ check in ═════════════════════════════════════════════════════════════
do $$
declare
  code text := tests.open_class();
  r jsonb; a uuid := tests.uid('ava');
begin
  perform tests.as_member('ava');

  perform tests.eq('a wrong code is refused', public.check_in('ZZZZZZ') ->> 'status', 'invalid');
  perform tests.eq('empty code is refused', public.check_in('') ->> 'status', 'invalid');
  perform tests.eq('null code is refused', public.check_in(null) ->> 'status', 'invalid');

  r := public.check_in(lower(substr(code, 1, 3)) || ' - ' || substr(code, 4));
  perform tests.eq('codes work in lower case, with spaces and dashes', r ->> 'status', 'ok');
  perform tests.eq('the first class is counted', r #>> '{stats,total_classes}', '1');
  perform tests.ok('the first class earns the First Class badge', r -> 'new_badges' @> '["first_class"]');
  perform tests.eq('the response names the class', r #>> '{class,class_type}', 'mat_pilates');

  -- a double-tap, or a retry after a dropped connection
  r := public.check_in(code);
  perform tests.eq('checking in twice is reported as already', r ->> 'status', 'already');
  perform tests.eq('the repeat does not count again', r #>> '{stats,total_classes}', '1');
  perform tests.eq('the repeat awards nothing again', r -> 'new_badges', '[]'::jsonb);
  perform tests.eq('exactly one check-in row exists', (select count(*)::int from public.checkins where member_id = a), 1);
  perform tests.eq('exactly one badge row exists', (select count(*)::int from public.member_badges where member_id = a), 1);
  perform tests.logout();
  perform tests.eq('failed guesses were logged, successes were not', (select count(*)::int from public.checkin_attempts where member_id = a), 3);
end $$;

-- the window around a class
do $$
declare code_early text; code_late text; code_soon text; code_over text; r jsonb;
begin
  code_soon  := tests.open_class('yoga_flow', now() + interval '40 minutes');   -- opens 45 min before
  code_early := tests.open_class('yoga_flow', now() + interval '50 minutes');   -- too early
  code_late  := tests.open_class('yoga_flow', now() - interval '79 minutes');   -- ends at +50, open to +80
  code_over  := tests.open_class('yoga_flow', now() - interval '81 minutes');   -- just closed
  perform tests.as_member('ben');
  perform tests.eq('50 minutes before the class is too early', public.check_in(code_early) ->> 'status', 'closed');
  perform tests.eq('81 minutes after the start is too late', public.check_in(code_over) ->> 'status', 'closed');
  perform tests.eq('40 minutes before the class is allowed', public.check_in(code_soon) ->> 'status', 'ok');
  perform tests.eq('79 minutes after the start is allowed', public.check_in(code_late) ->> 'status', 'ok');
  perform tests.logout();
end $$;

-- two a day, no more
do $$
declare c1 text; c2 text; c3 text;
begin
  c1 := tests.open_class('stretch', now()); c2 := tests.open_class('stretch', now() + interval '5 minutes'); c3 := tests.open_class('stretch', now() - interval '5 minutes');
  perform tests.as_member('cleo');
  perform tests.eq('first class of the day', public.check_in(c1) ->> 'status', 'ok');
  perform tests.eq('second class of the day', public.check_in(c2) ->> 'status', 'ok');
  perform tests.eq('a third class in a day is held back', public.check_in(c3) ->> 'status', 'limit');
  perform tests.eq('a held-back class is not counted', public.my_stats() ->> 'total_classes', '2');
  perform tests.eq('a repeat of a counted class is still just "already"', public.check_in(c1) ->> 'status', 'already');
  perform tests.logout();
end $$;

-- guessing codes
do $$
declare good text := tests.open_class(); i int; r jsonb;
begin
  perform tests.as_member('dan');
  for i in 1..8 loop perform public.check_in('NOPE' || i); end loop;
  perform tests.eq('after 8 wrong codes the screen locks', public.check_in(good) ->> 'status', 'throttled');
  perform tests.eq('and even the right code waits', public.check_in(good) ->> 'status', 'throttled');
  perform tests.eq('nothing was counted while locked', public.my_stats() ->> 'total_classes', '0');
  perform tests.logout();
  -- someone else is not affected
  perform tests.as_member('eli');
  perform tests.eq('another member is unaffected by the lock', public.check_in(good) ->> 'status', 'ok');
  perform tests.logout();
end $$;

-- ══ streaks and weeks (studio time is Phoenix, UTC-7, no daylight saving) ═
do $$
declare
  now_ts constant timestamptz := '2026-10-28 18:00:00+00';       -- Wed 11:00 in Phoenix; week began Mon Oct 26
  m uuid; s jsonb;
begin
  -- four weeks in a row up to and including this one
  m := tests.member('S1');
  perform tests.raw_checkin(m, t) from unnest(array['2026-10-06 18:00+00','2026-10-13 18:00+00','2026-10-20 18:00+00','2026-10-27 18:00+00']::timestamptz[]) t;
  s := public._stats(m, now_ts);
  perform tests.eq('4 weeks running: current streak', s ->> 'current_streak', '4');
  perform tests.eq('4 weeks running: longest streak', s ->> 'longest_streak', '4');

  -- last class was last week: the streak is still alive this week
  m := tests.member('S2');
  perform tests.raw_checkin(m, t) from unnest(array['2026-10-06 18:00+00','2026-10-13 18:00+00','2026-10-21 18:00+00']::timestamptz[]) t;
  s := public._stats(m, now_ts);
  perform tests.eq('last week''s class keeps the streak alive', s ->> 'current_streak', '3');

  -- missed a whole week: the streak is over but the best is remembered
  m := tests.member('S3');
  perform tests.raw_checkin(m, t) from unnest(array['2026-10-06 18:00+00','2026-10-13 18:00+00']::timestamptz[]) t;
  s := public._stats(m, now_ts);
  perform tests.eq('a missed week ends the streak', s ->> 'current_streak', '0');
  perform tests.eq('the best streak is remembered', s ->> 'longest_streak', '2');

  -- an old streak, a gap, then a newer one
  m := tests.member('S4');
  perform tests.raw_checkin(m, t) from unnest(array['2026-09-15 18:00+00','2026-09-22 18:00+00',
    '2026-10-06 18:00+00','2026-10-13 18:00+00','2026-10-20 18:00+00','2026-10-27 18:00+00']::timestamptz[]) t;
  s := public._stats(m, now_ts);
  perform tests.eq('a gap splits streaks: current counts only the latest run', s ->> 'current_streak', '4');
  perform tests.eq('a gap splits streaks: longest is the better run', s ->> 'longest_streak', '4');

  -- many classes in one week count once toward the streak
  m := tests.member('S5');
  perform tests.raw_checkin(m, t) from unnest(array['2026-10-26 15:00+00','2026-10-27 15:00+00','2026-10-28 15:00+00']::timestamptz[]) t;
  s := public._stats(m, now_ts);
  perform tests.eq('three classes in a week is a streak of one', s ->> 'current_streak', '1');
  perform tests.eq('but all three count as classes', s ->> 'total_classes', '3');
  perform tests.eq('and as this week''s classes', s ->> 'classes_this_week', '3');

  -- the week turns over at midnight Phoenix time, not midnight UTC
  m := tests.member('S6');       -- Sun Oct 25 23:30 Phoenix = Mon Oct 26 06:30 UTC: still LAST week's Sunday
  perform tests.raw_checkin(m, '2026-10-26 06:30+00');
  s := public._stats(m, now_ts);
  perform tests.eq('Sunday 11:30pm Phoenix belongs to the week that is ending', s ->> 'classes_this_week', '0');
  perform tests.eq('and keeps a one-week streak alive', s ->> 'current_streak', '1');

  m := tests.member('S7');       -- Mon Oct 26 00:30 Phoenix = Mon Oct 26 07:30 UTC: the new week
  perform tests.raw_checkin(m, '2026-10-25 06:30+00');      -- Sat Oct 24 23:30 Phoenix, previous week
  perform tests.raw_checkin(m, '2026-10-26 07:30+00');
  s := public._stats(m, now_ts);
  perform tests.eq('Monday 12:30am Phoenix starts the new week', s ->> 'classes_this_week', '1');
  perform tests.eq('two neighbouring weeks make a streak of two', s ->> 'current_streak', '2');

  perform tests.eq('a member with no classes has no streak', public._stats(tests.member('S8'), now_ts) ->> 'current_streak', '0');
end $$;

-- ══ badges and perks ═════════════════════════════════════════════════════
do $$
declare m uuid := tests.member('Gina'); i int; code text; r jsonb; num int; perk uuid;
begin
  -- 24 past classes, one a week, ending last week
  for i in 1..24 loop perform tests.raw_checkin(m, now() - make_interval(weeks => i)); end loop;
  code := tests.open_class();
  perform tests.as_member('gina');
  r := public.check_in(code);
  perform tests.eq('the 25th class is counted', r #>> '{stats,total_classes}', '25');
  perform tests.ok('the 25th class earns every class badge up to 25',
    r -> 'new_badges' @> '["first_class","classes_10","classes_25"]' and not (r -> 'new_badges' @> '["classes_50"]'));
  perform tests.ok('25 weeks in a row earns the streak badges', r -> 'new_badges' @> '["streak_4","streak_8","streak_12"]');
  perform tests.eq('the free class perk is earned at 25', r -> 'new_perks', '["free_class_25"]'::jsonb);
  perform tests.eq('a repeat awards nothing new', public.check_in(code) -> 'new_badges', '[]'::jsonb);
  perform tests.eq('badges are stored once each', (select count(*)::int from public.member_badges where member_id = m), 6);
  perform tests.eq('my_stats lists the earned badges', jsonb_array_length(public.my_stats() -> 'badges'), 6);
  perform tests.eq('my_stats lists the perk, unredeemed', public.my_stats() #>> '{perks,0,redeemed_at}', null);
  perk := (public.my_stats() #>> '{perks,0,id}')::uuid;
  num := (public.my_stats() #>> '{profile,member_number}')::int;
  perform tests.logout();

  -- the front desk redeems it, once
  perform tests.as_member('front');
  r := public.staff_member_lookup(num);
  perform tests.eq('staff can look a member up by number', r ->> 'display_name', 'Gina');
  perform tests.eq('and see the perk', r #>> '{perks,0,title}', 'Free class');
  perform tests.eq('staff redeem the perk', public.staff_redeem_perk(perk) ->> 'status', 'ok');
  perform tests.eq('a second redeem is refused', public.staff_redeem_perk(perk) ->> 'status', 'already_redeemed');
  perform tests.eq('an unknown perk is not found', public.staff_redeem_perk(gen_random_uuid()) ->> 'status', 'not_found');
  perform tests.eq('an unknown member is not found', public.staff_member_lookup(999999) ->> 'status', 'not_found');
  perform tests.logout();

  perform tests.as_member('gina');
  perform tests.ok('the member sees it as redeemed', public.my_stats() #>> '{perks,0,redeemed_at}' is not null);
  perform tests.eq('history lists classes, newest first', (select count(*)::int from public.my_history(100)), 25);
  perform tests.ok('history is newest first', (select checked_in_at from public.my_history(1)) >= (select min(checked_in_at) from public.my_history(100)));
  perform tests.logout();
end $$;

-- ══ staff: classes and codes ═════════════════════════════════════════════
do $$
declare r jsonb; i int; bad int; lo int; hi int;
begin
  perform tests.as_member('front');
  perform tests.eq('unknown class type is refused', public.staff_create_class('nope', now(), 50, 'A', 5) ->> 'status', 'invalid_class_type');
  perform tests.eq('a 5-minute class is refused', public.staff_create_class('stretch', now(), 5, 'A', 5) ->> 'status', 'invalid');
  perform tests.eq('a class with no instructor is refused', public.staff_create_class('stretch', now(), 50, '  ', 5) ->> 'status', 'invalid');
  perform tests.eq('a class with no room is refused', public.staff_create_class('stretch', now(), 50, 'A', 0) ->> 'status', 'invalid');
  r := public.staff_create_class('stretch', '2026-03-14 06:30+00', 50, 'Mia', 10);   -- Fri Mar 13, 11:30pm in Phoenix
  perform tests.ok('a code is six characters from the clear alphabet', r ->> 'code' ~ '^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$');
  r := public.staff_create_class('stretch', '2026-03-14 07:30+00', 50, 'Mia', 10);   -- Sat Mar 14, 12:30am in Phoenix
  perform tests.eq('the front desk list follows Phoenix time (before midnight)',
    jsonb_array_length(public.staff_classes('2026-03-13')), 1);
  perform tests.eq('the front desk list follows Phoenix time (after midnight)',
    jsonb_array_length(public.staff_classes('2026-03-14')), 1);
  perform tests.eq('the front desk list shows the code', public.staff_classes('2026-03-14') #>> '{0,code}', r ->> 'code');
  perform tests.eq('a day with no classes is an empty list', public.staff_classes('2030-01-01'), '[]'::jsonb);
  perform tests.logout();

  -- the code generator: right alphabet, no bias
  select count(*) into bad from generate_series(1, 3000) g where public._new_code() !~ '^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$';
  perform tests.eq('3,000 generated codes all use the clear alphabet', bad, 0);
  create temp table if not exists code_chars (ch text);
  insert into code_chars select substr(public._new_code(), g % 6 + 1, 1) from generate_series(1, 32000) g;
  select min(c), max(c) into lo, hi from (select count(*) c from code_chars group by ch) t;
  perform tests.ok('every letter is about equally likely (' || lo || ' to ' || hi || ' of ~1000)', lo > 800 and hi < 1200);
  perform tests.eq('and exactly 32 letters appear', (select count(distinct ch)::int from code_chars), 32);
end $$;

-- ══ the wall ═════════════════════════════════════════════════════════════
do $$
declare r jsonb; c uuid; i int; p1 uuid; p2 uuid; pid uuid; seen uuid[]; page record; last_at timestamptz; last_id uuid; total int;
begin
  perform tests.as_member('ava');
  c := gen_random_uuid();
  r := public.wall_post(c, 'Did my first handstand today!');
  perform tests.eq('a post is accepted', r ->> 'status', 'ok');
  p1 := (r ->> 'id')::uuid;
  r := public.wall_post(c, 'Did my first handstand today!');
  perform tests.eq('a retried post is recognised', r ->> 'duplicate', 'true');
  perform tests.eq('and returns the same post', (r ->> 'id')::uuid, p1);
  perform tests.eq('and is not posted twice', (select count(*)::int from public.wall_feed(null, null, 50) where is_mine), 1);
  perform tests.eq('an empty post is refused', public.wall_post(gen_random_uuid(), '   ') ->> 'status', 'invalid_body');
  perform tests.eq('a 501-character post is refused', public.wall_post(gen_random_uuid(), repeat('x', 501)) ->> 'status', 'invalid_body');
  perform tests.eq('a post with no id is refused', public.wall_post(null, 'hi') ->> 'status', 'invalid');
  for i in 2..5 loop perform tests.eq('post ' || i || ' of 5 in an hour', public.wall_post(gen_random_uuid(), 'Post number ' || i) ->> 'status', 'ok'); end loop;
  perform tests.eq('a sixth post in an hour waits', public.wall_post(gen_random_uuid(), 'One more') ->> 'status', 'rate_limited');
  perform tests.eq('a retry of an old post still succeeds while rate limited', public.wall_post(c, 'Did my first handstand today!') ->> 'duplicate', 'true');
  perform tests.logout();

  perform tests.as_member('ben');
  for i in 1..4 loop perform public.wall_post(gen_random_uuid(), 'Ben post ' || i); end loop;
  perform tests.eq('another member has their own limit', (select count(*)::int from public.wall_feed(null, null, 50) where is_mine), 4);
  perform tests.eq('members see everyone''s posts', (select count(*)::int from public.wall_feed(null, null, 50)), 9);
  perform tests.eq('a post shows only a name and avatar', (select author_name from public.wall_feed(null, null, 50) where not is_mine limit 1), 'Ava');
  perform tests.ok('the feed returns no email or member number',
    pg_get_function_result('public.wall_feed(timestamptz,uuid,int)'::regprocedure) !~* 'email|member_number');

  -- walk the feed two at a time: nothing missing, nothing twice
  seen := '{}'; last_at := null; last_id := null; total := 0;
  loop
    select count(*), (array_agg(created_at order by created_at, id))[1], (array_agg(id order by created_at, id))[1]
      into i, last_at, last_id from public.wall_feed(last_at, last_id, 2);
    exit when i = 0;
    total := total + i;
    seen := seen || (select array_agg(id) from public.wall_feed(null, null, 50) where id = last_id);
    exit when total >= 40;
  end loop;
  perform tests.eq('paging through the feed reaches every post exactly once', total, 9);

  -- cheers
  pid := p1;
  perform tests.eq('cheering a post', public.wall_cheer(pid, true) ->> 'cheers', '1');
  perform tests.eq('cheering again changes nothing', public.wall_cheer(pid, true) ->> 'cheers', '1');
  perform tests.eq('the post shows I cheered it', (select cheered_by_me from public.wall_feed(null, null, 50) where id = pid), true);
  perform tests.eq('un-cheering', public.wall_cheer(pid, false) ->> 'cheers', '0');
  perform tests.eq('un-cheering again changes nothing', public.wall_cheer(pid, false) ->> 'cheers', '0');
  perform tests.eq('cheering a post that does not exist adds nothing', public.wall_cheer(gen_random_uuid(), true) ->> 'cheers', '0');
  perform public.wall_cheer(pid, true);
  perform tests.logout();

  -- reports hide a post after three different members report it
  perform tests.as_member('ava');
  perform public.wall_report(pid);
  perform tests.logout();
  perform tests.eq('you cannot report your own post', (select count(*)::int from public.wall_reports where post_id = pid), 0);
  perform tests.as_member('ben');  perform public.wall_report(pid); perform public.wall_report(pid);
  perform tests.logout();
  perform tests.eq('one member reporting twice counts once', (select count(*)::int from public.wall_reports where post_id = pid), 1);
  perform tests.as_member('cleo'); perform public.wall_report(pid);
  perform tests.eq('two reports are not enough to hide a post', (select count(*)::int from public.wall_feed(null, null, 50) where id = pid), 1);
  perform tests.logout();
  perform tests.as_member('dan');  perform public.wall_report(pid);
  perform tests.eq('three different reports hide a post', (select count(*)::int from public.wall_feed(null, null, 50) where id = pid), 0);
  perform public.wall_cheer(pid, true);
  perform tests.logout();
  perform tests.eq('a hidden post cannot be cheered', (select count(*)::int from public.wall_cheers where post_id = pid), 1);

  -- staff review
  perform tests.as_member('front');
  r := public.staff_flagged_posts();
  perform tests.eq('staff see the flagged post', jsonb_array_length(r), 1);
  perform tests.eq('with its report count', r #>> '{0,reports}', '3');
  perform tests.eq('and why it is hidden', r #>> '{0,hidden_reason}', 'reported');
  perform tests.eq('staff can put it back', public.staff_set_post_hidden(pid, false) ->> 'status', 'ok');
  perform tests.eq('and then members see it again', (select count(*)::int from public.wall_feed(null, null, 50) where id = pid), 1);
  perform tests.eq('staff can hide any post', public.staff_set_post_hidden(pid, true, 'off topic') ->> 'status', 'ok');
  perform tests.eq('hiding a missing post says so', public.staff_set_post_hidden(gen_random_uuid(), true) ->> 'status', 'not_found');
  perform tests.logout();
end $$;

-- ══ deleting an account ══════════════════════════════════════════════════
do $$
declare d uuid := tests.member('Zed'); code text := tests.open_class(); other uuid; pid uuid;
begin
  perform tests.login(d);
  perform public.check_in(code);
  perform public.wall_post(gen_random_uuid(), 'Zed was here');
  pid := (select id from public.wall_feed(null, null, 50) where author_name = 'Ben' limit 1);
  perform public.wall_cheer(pid, true);
  perform public.wall_report(pid);
  perform tests.eq('before deleting, the account has data', (select count(*)::int from public.checkins), 1);
  perform tests.eq('deleting the account says so', public.delete_my_account() ->> 'status', 'deleted');
  perform tests.logout();

  perform tests.eq('the sign-in is gone', (select count(*)::int from auth.users where id = d), 0);
  perform tests.eq('the profile is gone', (select count(*)::int from public.profiles where id = d), 0);
  perform tests.eq('their check-ins are gone', (select count(*)::int from public.checkins where member_id = d), 0);
  perform tests.eq('their badges are gone', (select count(*)::int from public.member_badges where member_id = d), 0);
  perform tests.eq('their posts are gone', (select count(*)::int from public.wall_posts where author_id = d), 0);
  perform tests.eq('their cheers are gone', (select count(*)::int from public.wall_cheers where member_id = d), 0);
  perform tests.eq('their reports are gone', (select count(*)::int from public.wall_reports where reporter_id = d), 0);
  perform tests.ok('other members are untouched', (select count(*) from public.wall_posts where author_id = tests.uid('ben')) = 4);
end $$;

rollback;
\echo flows: all checks passed
