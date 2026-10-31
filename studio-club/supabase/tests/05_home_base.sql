-- The home base: public forms, events, the teachers' journal, social
-- calendar and audience. Runs as the real API roles.
\set ON_ERROR_STOP on
\set QUIET on
set client_min_messages = notice;
begin;

create or replace function tests.teacher(p_name text) returns uuid language plpgsql as $$
declare v_id uuid := tests.member(p_name); v_staff uuid; r jsonb;
begin
  select user_id into v_staff from public.staff limit 1;
  perform tests.login(v_staff);
  r := public.staff_add_teacher(lower(p_name) || '@example.test', p_name, 'Teaches things.');
  perform tests.logout();
  if r ->> 'status' <> 'ok' then raise exception 'could not make teacher: %', r; end if;
  return v_id;
end $$;

select tests.staff('Desk')   as desk   \gset
select tests.member('Mia')   as mia    \gset
select tests.teacher('Tara') as tara   \gset
select tests.teacher('Tess') as tess   \gset

-- ── privacy ────────────────────────────────────────────────────────────────
do $$
declare f record; n int;
begin
  perform tests.login(tests.uid('Mia'));
  perform tests.eq('a member sees no leads', (select count(*)::int from public.leads), 0);
  perform tests.throws('a member cannot read events directly', 'select * from public.events', '42501');
  perform tests.throws('a member cannot read journal posts directly', 'select * from public.journal_posts', '42501');
  perform tests.throws('a member cannot read teachers directly', 'select * from public.teachers', '42501');
  perform tests.throws('a member cannot write leads directly', $q$insert into public.leads (client_id, kind, name, contact, contact_norm) values (gen_random_uuid(), 'signup', 'x', 'abcde', 'abcde')$q$, '42501');
  -- every staff function refuses everyone who is not staff, before looking at anything else
  for f in select p.proname, p.pronargs from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
           where ns.nspname = 'public' and p.prokind = 'f' and p.proname like 'staff\_%' loop
    perform tests.throws('a plain member cannot run ' || f.proname,
      format('select public.%I(%s)', f.proname, (select coalesce(string_agg('null', ','), '') from generate_series(1, f.pronargs))), '42501');
  end loop;
  perform tests.logout();
  perform tests.login(tests.uid('Tara'));
  for f in select p.proname, p.pronargs from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
           where ns.nspname = 'public' and p.prokind = 'f' and p.proname like 'staff\_%' loop
    perform tests.throws('a teacher cannot run ' || f.proname,
      format('select public.%I(%s)', f.proname, (select coalesce(string_agg('null', ','), '') from generate_series(1, f.pronargs))), '42501');
  end loop;
  perform tests.logout();
  perform tests.login(tests.uid('Desk'));
  perform tests.eq('staff can read the leads table', (select count(*)::int from public.leads), 0);
  perform tests.logout();
  perform tests.anon();
  perform tests.throws('a signed-out visitor cannot ask who the teachers are by email', 'select public.staff_teachers()', '42501');
  perform tests.throws('a signed-out visitor cannot write a post', $q$select public.post_save(gen_random_uuid(), null, 'post', 'x', 'y')$q$, '42501');
  perform tests.logout();
end $$;

-- ── forms ──────────────────────────────────────────────────────────────────
do $$
declare cid uuid := gen_random_uuid(); r jsonb; n int;
begin
  perform tests.anon();
  r := public.submit_form(cid, 'event_request', 'Sam Host', 'sam@example.test', '{"event":"Sound bath","spots":"12"}', true, 'instagram');
  perform tests.eq('a signed-out visitor can send an event request', r ->> 'status', 'ok');
  r := public.submit_form(cid, 'event_request', 'Sam Host', 'sam@example.test', '{"event":"Sound bath","spots":"12"}', true, 'instagram');
  perform tests.eq('sending it again (a retry) is still ok', r ->> 'status', 'ok');
  perform tests.logout();
  perform tests.eq('a retry did not make a second lead', (select count(*)::int from public.leads where client_id = cid), 1);
  perform tests.eq('the email was filed as an email', (select email from public.leads where client_id = cid), 'sam@example.test');
  perform tests.eq('the source was kept', (select source from public.leads where client_id = cid), 'instagram');
  perform tests.eq('it starts as new', (select status from public.leads where client_id = cid), 'new');

  perform tests.anon();
  r := public.submit_form(gen_random_uuid(), 'partner_request', 'Cafe Owner', '480 555 0142', '{"idea":"pastries and tea"}', false, null);
  perform tests.eq('a phone number works as contact', r ->> 'status', 'ok');
  perform tests.eq('bad kind is refused', public.submit_form(gen_random_uuid(), 'hack', 'A', 'a@example.test') ->> 'status', 'invalid');
  perform tests.eq('missing name is refused', public.submit_form(gen_random_uuid(), 'signup', '  ', 'a@example.test') ->> 'status', 'invalid');
  perform tests.eq('a contact that is not email or phone is refused', public.submit_form(gen_random_uuid(), 'signup', 'A', 'hello') ->> 'status', 'invalid');
  perform tests.eq('missing client id is refused', public.submit_form(null, 'signup', 'A', 'a@example.test') ->> 'status', 'invalid');
  perform tests.eq('an oversized form is refused', public.submit_form(gen_random_uuid(), 'signup', 'A', 'a@example.test', jsonb_build_object('x', repeat('z', 5000))) ->> 'status', 'invalid');
  perform tests.eq('fields that are not an object are refused', public.submit_form(gen_random_uuid(), 'signup', 'A', 'a@example.test', '[1,2]') ->> 'status', 'invalid');
  perform tests.eq('nulls everywhere do not crash', public.submit_form(null, null, null, null, null, null, null, null) ->> 'status', 'invalid');
  r := public.submit_form(gen_random_uuid(), 'signup', 'Robot', 'robot@example.test', '{}', true, null, 'http://spam');
  perform tests.eq('a bot that fills the hidden field is told ok', r ->> 'status', 'ok');
  perform tests.logout();
  perform tests.eq('and nothing was stored for it', (select count(*)::int from public.leads where contact_norm = 'robot@example.test'), 0);

  perform tests.anon();
  for n in 1..5 loop perform public.submit_form(gen_random_uuid(), 'signup', 'Eager', 'eager@example.test'); end loop;
  perform tests.eq('a sixth form in an hour from one contact waits', public.submit_form(gen_random_uuid(), 'signup', 'Eager', 'eager@example.test') ->> 'status', 'rate_limited');
  perform tests.eq('another contact is unaffected', public.submit_form(gen_random_uuid(), 'signup', 'Other', 'other@example.test') ->> 'status', 'ok');
  perform tests.logout();
  perform tests.eq('exactly five were stored for the eager contact', (select count(*)::int from public.leads where contact_norm = 'eager@example.test'), 5);

  insert into public.leads (client_id, kind, name, contact, contact_norm)
    select gen_random_uuid(), 'signup', 'Flood', 'f' || g || '@example.test', 'f' || g || '@example.test' from generate_series(1, 300) g;
  perform tests.anon();
  perform tests.eq('a flood across many contacts is slowed down', public.submit_form(gen_random_uuid(), 'signup', 'Late', 'late@example.test') ->> 'status', 'busy');
  perform tests.logout();
  delete from public.leads where name = 'Flood';
end $$;

-- ── events ─────────────────────────────────────────────────────────────────
do $$
declare r jsonb; ev uuid; past uuid; hidden uuid; cid uuid; l uuid; txt text;
begin
  perform tests.login(tests.uid('Desk'));
  r := public.staff_save_event(null, 'The Deep Release', 'A slow evening.', now() + interval '3 days', now() + interval '3 days 2 hours', null, '$25', 2, 'https://example.test/book', 'Tara', true);
  perform tests.eq('staff can create an event', r ->> 'status', 'ok'); ev := (r ->> 'id')::uuid;
  past   := (public.staff_save_event(null, 'Old news', '', now() - interval '3 days', null, null, null, null, null, null, true) ->> 'id')::uuid;
  hidden := (public.staff_save_event(null, 'Secret plan', '', now() + interval '5 days', null, null, null, null, null, null, false) ->> 'id')::uuid;
  perform tests.eq('a bad link is refused', public.staff_save_event(null, 'Bad', '', now(), null, null, null, null, 'javascript:alert(1)', null, true) ->> 'status', 'invalid');
  perform tests.eq('ending before starting is refused', public.staff_save_event(null, 'Bad', '', now(), now() - interval '1 hour', null, null, null, null, null, true) ->> 'status', 'invalid');
  perform tests.logout();

  perform tests.anon();
  txt := public.public_events()::text;
  perform tests.ok('the public sees the upcoming published event', txt like '%The Deep Release%');
  perform tests.ok('not past events', txt not like '%Old news%');
  perform tests.ok('not unpublished events', txt not like '%Secret plan%');
  perform tests.eq('two spots left to start', (public.public_events() -> 0 ->> 'spots_left')::int, 2);
  perform tests.eq('signing up for the event', public.event_signup(gen_random_uuid(), ev, 'Ann', 'ann@example.test', true, 'qr_deep') ->> 'status', 'ok');
  cid := gen_random_uuid();
  perform tests.eq('a second person', public.event_signup(cid, ev, 'Bo', 'bo@example.test', false) ->> 'status', 'ok');
  perform tests.eq('a retry of the same signup is fine', public.event_signup(cid, ev, 'Bo', 'bo@example.test', false) ->> 'status', 'ok');
  perform tests.eq('the same person signing up again with a new tap is fine', public.event_signup(gen_random_uuid(), ev, 'Bo', 'BO@example.test', false) ->> 'status', 'ok');
  perform tests.eq('the event is now full', public.event_signup(gen_random_uuid(), ev, 'Cy', 'cy@example.test') ->> 'status', 'full');
  perform tests.eq('no spots left shown', (public.public_events() -> 0 ->> 'spots_left')::int, 0);
  perform tests.eq('an unpublished event is closed', public.event_signup(gen_random_uuid(), hidden, 'Di', 'di@example.test') ->> 'status', 'closed');
  perform tests.eq('a past event is closed', public.event_signup(gen_random_uuid(), past, 'Di', 'di@example.test') ->> 'status', 'closed');
  perform tests.eq('an event that does not exist is closed', public.event_signup(gen_random_uuid(), gen_random_uuid(), 'Di', 'di@example.test') ->> 'status', 'closed');
  txt := public.public_events()::text;
  perform tests.ok('the public list never shows who signed up', txt not like '%ann@example.test%' and txt not like '%Ann%');
  perform tests.logout();
  perform tests.eq('exactly two signups were stored', (select count(*)::int from public.leads where event_id = ev), 2);

  perform tests.login(tests.uid('Desk'));
  perform tests.eq('staff see the signups', jsonb_array_length(public.staff_event_signups(ev)), 2);
  l := (select id from public.leads where contact_norm = 'ann@example.test');
  perform tests.eq('marking someone as attended', public.staff_mark_attended(l, true) ->> 'status', 'ok');
  perform tests.eq('the event counts attendance', (select (e ->> 'attended')::int from jsonb_array_elements(public.staff_events()) e where e ->> 'title' = 'The Deep Release'), 1);
  perform tests.eq('freeing a spot by marking spam', public.staff_lead_set((select id from public.leads where contact_norm = 'bo@example.test'), 'spam') ->> 'status', 'ok');
  perform tests.logout();
  perform tests.anon();
  perform tests.eq('a spot opened up', (public.public_events() -> 0 ->> 'spots_left')::int, 1);
  perform tests.eq('and someone else can take it', public.event_signup(gen_random_uuid(), ev, 'Cy', 'cy@example.test') ->> 'status', 'ok');
  perform tests.logout();

  perform tests.login(tests.uid('Desk'));
  perform tests.eq('deleting an event with signups only hides it', public.staff_delete_event(ev) ->> 'status', 'hidden');
  perform tests.eq('deleting an empty event removes it', public.staff_delete_event(hidden) ->> 'status', 'ok');
  perform tests.logout();
  perform tests.eq('the signups were kept', (select count(*)::int from public.leads where event_id = ev), 3);
end $$;

-- ── the inbox ──────────────────────────────────────────────────────────────
do $$
declare l uuid; n int;
begin
  perform tests.login(tests.uid('Desk'));
  perform tests.ok('the inbox shows new forms, newest first', jsonb_array_length(public.staff_inbox('new', array['event_request', 'partner_request'])) >= 2);
  perform tests.eq('a kind filter works', jsonb_array_length(public.staff_inbox('new', array['partner_request'])), 1);
  l := (select id from public.leads where kind = 'partner_request');
  perform tests.eq('staff can mark a lead seen with a note', public.staff_lead_set(l, 'seen', 'called back') ->> 'status', 'ok');
  perform tests.eq('the note is kept', (select note from public.leads where id = l), 'called back');
  perform tests.eq('a bad status is refused', public.staff_lead_set(l, 'weird') ->> 'status', 'invalid');
  perform tests.eq('a missing lead says so', public.staff_lead_set(gen_random_uuid(), 'done') ->> 'status', 'not_found');
  perform tests.ok('counts exist', (public.staff_inbox_counts() ->> 'new')::int > 0);
  perform tests.logout();
  perform tests.login(tests.uid('Mia'));
  perform tests.eq('with leads in the table, a member still sees none', (select count(*)::int from public.leads), 0);
  perform tests.logout();
  perform tests.login(tests.uid('Tara'));
  perform tests.eq('and neither does a teacher', (select count(*)::int from public.leads), 0);
  perform tests.logout();
end $$;

-- ── teachers and the journal ───────────────────────────────────────────────
do $$
declare r jsonb; post uuid; cid uuid := gen_random_uuid(); slug text; mypost uuid;
begin
  perform tests.login(tests.uid('Mia'));
  perform tests.throws('a plain member cannot write a post', $q$select public.post_save(gen_random_uuid(), null, 'post', 'x', 'y')$q$, '42501');
  perform tests.logout();

  perform tests.login(tests.uid('Desk'));
  perform tests.eq('adding a teacher who has never signed in says so', public.staff_add_teacher('nobody@example.test', 'Nobody') ->> 'status', 'no_such_user');
  perform tests.eq('teachers are listed for staff', jsonb_array_length(public.staff_teachers()), 2);
  perform tests.logout();
  perform tests.anon();
  perform tests.ok('the public sees teachers without emails', public.public_teachers()::text like '%Tara%' and public.public_teachers()::text not like '%@%');
  perform tests.logout();

  perform tests.login(tests.uid('Tara'));
  perform tests.eq('my_role knows a teacher', (public.my_role() ->> 'teacher')::boolean, true);
  perform tests.eq('and that she is not staff', (public.my_role() ->> 'staff')::boolean, false);
  r := public.post_save(cid, null, 'teacher_of_week', 'Meet Tess', 'Tess started this month.' || chr(10) || chr(10) || 'She loves slow flow.', 'https://example.test/tess.jpg');
  perform tests.eq('a teacher saves a draft', r ->> 'status', 'ok'); post := (r ->> 'id')::uuid;
  perform tests.eq('saving the same draft again (a retry) returns the same post', (public.post_save(cid, null, 'teacher_of_week', 'Meet Tess', 'Tess started this month.') ->> 'id')::uuid, post);
  perform tests.eq('an empty title is refused', public.post_save(gen_random_uuid(), null, 'post', '', 'body') ->> 'status', 'invalid');
  perform tests.eq('a cover that is not https is refused', public.post_save(gen_random_uuid(), null, 'post', 't', 'b', 'http://x') ->> 'status', 'invalid');
  perform tests.eq('a made-up kind is refused', public.post_save(gen_random_uuid(), null, 'post-ish', 't', 'b') ->> 'status', 'invalid');
  perform tests.eq('the post is a draft', public.post_get(post) ->> 'status', 'draft');
  perform tests.eq('the byline is the teacher''s name', public.post_get(post) ->> 'author', 'Tara');
  perform tests.throws('a teacher cannot publish', format('select public.staff_review_post(%L, ''publish'')', post), '42501');
  perform tests.eq('submitting for review', public.post_submit(post) ->> 'status', 'ok');
  perform tests.eq('submitting twice is fine', public.post_submit(post) ->> 'status', 'ok');
  perform tests.logout();

  perform tests.anon();
  perform tests.eq('a submitted post is not public', jsonb_array_length(public.public_journal()), 0);
  perform tests.logout();

  perform tests.login(tests.uid('Tess'));
  perform tests.eq('another teacher cannot read it', public.post_get(post), null);
  perform tests.eq('another teacher cannot edit it', public.post_save(gen_random_uuid(), post, 'post', 'Mine now', 'x') ->> 'status', 'not_found');
  perform tests.eq('another teacher cannot submit it', public.post_submit(post) ->> 'status', 'not_found');
  perform tests.eq('another teacher does not see it in her list', jsonb_array_length(public.my_posts()), 0);
  perform tests.logout();

  perform tests.login(tests.uid('Desk'));
  perform tests.eq('staff see every post', jsonb_array_length(public.my_posts()), 1);
  perform tests.eq('staff can send a post back with a note', public.staff_review_post(post, 'reject', 'Add a photo credit') ->> 'status', 'ok');
  perform tests.logout();
  perform tests.login(tests.uid('Tara'));
  perform tests.eq('the teacher sees why', public.post_get(post) ->> 'review_note', 'Add a photo credit');
  perform tests.eq('and can fix it', public.post_save(gen_random_uuid(), post, 'teacher_of_week', 'Meet Tess', 'Tess started this month. Photo by Mia.') ->> 'status', 'ok');
  perform tests.eq('which puts it back to draft', public.post_get(post) ->> 'status', 'draft');
  perform tests.eq('and she resubmits', public.post_submit(post) ->> 'status', 'ok');
  perform tests.logout();

  perform tests.login(tests.uid('Desk'));
  r := public.staff_review_post(post, 'publish');
  perform tests.eq('staff publish it', r ->> 'status', 'ok'); slug := r ->> 'slug';
  perform tests.eq('publishing twice is fine and keeps the same address', public.staff_review_post(post, 'publish') ->> 'slug', slug);
  perform tests.logout();

  perform tests.anon();
  perform tests.eq('now the public sees it', jsonb_array_length(public.public_journal()), 1);
  perform tests.eq('with the teacher''s name', public.public_journal() -> 0 ->> 'author', 'Tara');
  perform tests.ok('and an excerpt but not the whole body in the list', not (public.public_journal() -> 0 ? 'body'));
  perform tests.ok('the post page has the whole body', public.public_post(slug) ->> 'body' like '%Photo by Mia%');
  perform tests.eq('an unknown address finds nothing', public.public_post('nope'), null);
  perform tests.eq('paging past the only post finds none', jsonb_array_length(public.public_journal(10, now() - interval '1 year')), 0);
  perform tests.logout();

  perform tests.login(tests.uid('Tara'));
  perform tests.eq('a teacher cannot edit a published post', public.post_save(gen_random_uuid(), post, 'post', 'Changed', 'x') ->> 'status', 'locked');
  r := public.post_save(gen_random_uuid(), null, 'post', 'Second', 'Another one.');
  mypost := (r ->> 'id')::uuid;
  perform tests.eq('a published post cannot be submitted again', public.post_submit(post) ->> 'status', 'invalid_state');
  perform tests.eq('a teacher can update her own profile', public.teacher_save_profile('Tara T', 'Loves yin.', 'https://example.test/t.jpg') ->> 'status', 'ok');
  perform tests.eq('a bad photo link is refused', public.teacher_save_profile('Tara T', null, 'ftp://x') ->> 'status', 'invalid');
  perform tests.logout();

  perform tests.login(tests.uid('Desk'));
  perform tests.eq('staff can take a post down', public.staff_review_post(post, 'unpublish') ->> 'status', 'ok');
  perform tests.logout();
  perform tests.anon();
  perform tests.eq('and it leaves the public journal', jsonb_array_length(public.public_journal()), 0);
  perform tests.eq('and its page', public.public_post(slug), null);
  perform tests.logout();

  perform tests.login(tests.uid('Desk'));
  perform tests.eq('removing a teacher', public.staff_remove_teacher(tests.uid('Tess')) ->> 'status', 'ok');
  perform tests.logout();
  perform tests.login(tests.uid('Tess'));
  perform tests.throws('a removed teacher cannot write any more', $q$select public.post_save(gen_random_uuid(), null, 'post', 'x', 'y')$q$, '42501');
  perform tests.logout();
end $$;

-- ── social calendar ────────────────────────────────────────────────────────
do $$
declare r jsonb; sp uuid;
begin
  perform tests.login(tests.uid('Desk'));
  r := public.staff_social_save(null, now() + interval '1 day', 'feed', 'Teacher of the week: Tara', null, 'draft');
  perform tests.eq('a post can be planned', r ->> 'status', 'ok'); sp := (r ->> 'id')::uuid;
  perform tests.eq('it can be moved and approved', public.staff_social_save(sp, now() + interval '2 days', 'story', 'Teacher of the week: Tara', null, 'approved') ->> 'status', 'ok');
  perform tests.eq('the calendar lists it', jsonb_array_length(public.staff_social_list(now(), now() + interval '7 days')), 1);
  perform tests.eq('a bad kind is refused', public.staff_social_save(null, now(), 'tv', 'x') ->> 'status', 'invalid');
  perform tests.eq('a caption over 2200 characters is refused', public.staff_social_save(null, now(), 'feed', repeat('x', 2300)) ->> 'status', 'invalid');
  perform tests.eq('it can be deleted', public.staff_social_delete(sp) ->> 'status', 'ok');
  perform tests.logout();
end $$;

-- ── audience: only people who said yes, never anyone who unsubscribed ───────
do $$
declare ev uuid; tok uuid; n int;
begin
  ev := (select id from public.events where title = 'The Deep Release');
  perform tests.login(tests.uid('Desk'));
  perform tests.ok('the audience includes people who agreed', public.staff_audience('consented')::text like '%ann@example.test%');
  perform tests.ok('but not people who did not', public.staff_audience('consented')::text not like '%bo@example.test%');
  perform tests.ok('and not spam', public.staff_audience('consented')::text not like '%robot%');
  perform tests.eq('people who came to an event', jsonb_array_length(public.staff_audience('event_attended', ev)), 1);
  perform tests.eq('partners are their own list', jsonb_array_length(public.staff_audience('partners')), 0);   -- the partner did not agree to updates
  perform tests.eq('a bad segment is refused', public.staff_audience('everyone') ->> 'status', 'invalid');
  perform tests.ok('the source report shows what each source brought', public.staff_source_report()::text like '%qr_deep%');
  perform tests.logout();

  tok := (select unsub_token from public.leads where contact_norm = 'ann@example.test');
  perform tests.anon();
  perform tests.eq('anyone with the link can unsubscribe', public.unsubscribe(tok) ->> 'status', 'ok');
  perform tests.eq('doing it twice is fine', public.unsubscribe(tok) ->> 'status', 'ok');
  perform tests.eq('a wrong link does nothing', public.unsubscribe(gen_random_uuid()) ->> 'status', 'not_found');
  perform tests.logout();
  perform tests.login(tests.uid('Desk'));
  perform tests.ok('after that, she is out of every list', public.staff_audience('consented')::text not like '%ann@example.test%');
  perform tests.eq('and out of the event list', jsonb_array_length(public.staff_audience('event_attended', ev)), 0);
  perform tests.logout();
end $$;

-- ── a teacher can delete her account ───────────────────────────────────────
do $$
begin
  perform tests.login(tests.uid('Tara'));
  perform public.delete_my_account();
  perform tests.logout();
  perform tests.eq('her posts are gone', (select count(*)::int from public.journal_posts where author_name like 'Tara%'), 0);
  perform tests.eq('her teacher record is gone', (select count(*)::int from public.teachers where display_name like 'Tara%'), 0);
  perform tests.ok('forms people sent are untouched', (select count(*) from public.leads) > 0);
end $$;

-- ── the photo bucket: each writer only inside their own folder ─────────────
do $$
declare me uuid := tests.uid('Desk'); other uuid := tests.uid('Tess');
begin
  perform tests.ok('the journal bucket exists and is public', exists (select 1 from storage.buckets where id = 'journal' and public));
  perform tests.login(me);
  insert into storage.objects (bucket_id, name) values ('journal', me::text || '/cover.jpg');
  perform tests.pass('staff can upload into their own folder');
  perform tests.throws('but not into someone else''s', format($q$insert into storage.objects (bucket_id, name) values ('journal', %L)$q$, other::text || '/x.jpg'), '42501');
  perform tests.logout();
  perform tests.login(tests.uid('Mia'));
  perform tests.throws('a plain member cannot upload at all', format($q$insert into storage.objects (bucket_id, name) values ('journal', %L)$q$, tests.uid('Mia')::text || '/x.jpg'), '42501');
  perform tests.logout();
end $$;

rollback;
\echo homebase: all checks passed
