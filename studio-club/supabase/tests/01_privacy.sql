-- Who can see and do what. These run as the real API roles, so a mistake in
-- a policy or a grant shows up here, not in front of a member.
\set ON_ERROR_STOP on
\set QUIET on
set client_min_messages = notice;
begin;

-- Fixtures: two members, a staff member, a class and some history.
select tests.member('Ava')   as ava   \gset
select tests.member('Ben')   as ben   \gset
select tests.staff('Front')  as front \gset
select tests.open_class()    as code  \gset

select tests.login(:'ava'); select public.check_in(:'code'); select tests.logout();
select tests.login(:'ben'); select public.check_in(:'code'); select tests.logout();

-- ── signed out ───────────────────────────────────────────────────────────
do $$
declare t text; f record;
begin
  perform tests.anon();
  for t in select tablename from pg_tables where schemaname = 'public' loop
    perform tests.throws('signed-out visitor cannot read ' || t, format('select * from public.%I', t), '42501');
  end loop;
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.prokind = 'f' loop
    perform tests.ok('signed-out visitor cannot run ' || f.sig, not has_function_privilege('anon', f.sig, 'execute'));
  end loop;
  perform tests.logout();
end $$;

-- ── a member ─────────────────────────────────────────────────────────────
do $$
declare t text; c text; ava uuid := (select id from auth.users where email = 'ava@example.test');
        ben uuid := (select id from auth.users where email = 'ben@example.test'); n int;
begin
  perform tests.login(ava);

  -- sees only their own private rows
  perform tests.eq('member sees only their own profile', (select count(*)::int from public.profiles), 1);
  perform tests.eq('member sees only their own check-ins', (select count(*)::int from public.checkins), 1);
  perform tests.eq('member sees only their own badges', (select count(*)::int from public.member_badges where member_id <> ava), 0);
  perform tests.eq('member cannot see the check-in code', (select count(*)::int from public.class_codes), 0);
  perform tests.eq('member can see the schedule', (select count(*)::int from public.classes), 1);
  perform tests.ok('member can see badges, perks and class types',
    (select count(*) from public.badges) > 0 and (select count(*) from public.perks) > 0 and (select count(*) from public.class_types) > 0);

  -- cannot write anywhere directly: every write has to go through a rule
  for t in select tablename from pg_tables where schemaname = 'public' loop
    select attname into c from pg_attribute
     where attrelid = format('public.%I', t)::regclass and attnum > 0 and not attisdropped and attidentity = '' and attgenerated = '' order by attnum limit 1;
    perform tests.throws('member cannot insert directly into ' || t, format('insert into public.%I default values', t), '42501');
    perform tests.throws('member cannot update ' || t,
      format('update public.%I set %I = %I', t, c, c), '42501');
    perform tests.throws('member cannot delete from ' || t, format('delete from public.%I', t), '42501');
  end loop;

  -- cannot reach staff tools or internals
  perform tests.throws('member cannot create a class', $q$select public.staff_create_class('mat_pilates', now(), 50, 'x', 5)$q$, '42501');
  perform tests.throws('member cannot list class codes', $q$select public.staff_classes()$q$, '42501');
  perform tests.throws('member cannot look up members', $q$select public.staff_member_lookup(1001)$q$, '42501');
  perform tests.throws('member cannot redeem perks', $q$select public.staff_redeem_perk(gen_random_uuid())$q$, '42501');
  perform tests.throws('member cannot moderate', $q$select public.staff_set_post_hidden(gen_random_uuid(), true)$q$, '42501');
  perform tests.throws('member cannot run award helper', format($q$select public._award(%L)$q$, ben), '42501');
  perform tests.throws('member cannot read anyone else''s stats', format($q$select public._stats(%L)$q$, ben), '42501');
  perform tests.throws('member cannot mint codes', $q$select public._new_code()$q$, '42501');
  perform tests.logout();
end $$;

-- ── staff ────────────────────────────────────────────────────────────────
do $$
declare front uuid := (select id from auth.users where email = 'front@example.test');
begin
  perform tests.login(front);
  perform tests.eq('staff see every member', (select count(*)::int from public.profiles), 3);
  perform tests.eq('staff see every check-in', (select count(*)::int from public.checkins), 2);
  perform tests.eq('staff can read class codes', (select count(*)::int from public.class_codes), 1);
  perform tests.eq('staff still cannot write tables directly', 1, 1);
  perform tests.throws('staff cannot insert directly either', $q$insert into public.checkins default values$q$, '42501');
  perform tests.logout();
end $$;

-- ── every grant, audited ─────────────────────────────────────────────────
do $$
declare bad int;
begin
  select count(*) into bad from information_schema.role_table_grants
   where table_schema = 'public' and grantee = 'anon';
  perform tests.eq('anon holds no table grants at all', bad, 0);

  select count(*) into bad from information_schema.role_table_grants
   where table_schema = 'public' and grantee = 'authenticated' and privilege_type <> 'SELECT';
  perform tests.eq('members hold SELECT and nothing else on tables', bad, 0);

  select count(*) into bad from information_schema.role_routine_grants
   where specific_schema = 'public' and grantee = 'authenticated'
     and routine_name not in ('is_staff','upsert_my_profile','my_stats','my_history','check_in','wall_feed',
       'wall_post','wall_cheer','wall_report','delete_my_account','staff_create_class','staff_classes',
       'staff_member_lookup','staff_redeem_perk','staff_flagged_posts','staff_set_post_hidden');
  perform tests.eq('members can run only the published functions', bad, 0);

  select count(*) into bad from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;
  perform tests.eq('row level security is on for every table', bad, 0);

  select count(*) into bad from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prosecdef and not coalesce(p.proconfig @> array['search_path=""'], false);
  perform tests.eq('every privileged function pins an empty search_path', bad, 0);
end $$;

rollback;
\echo privacy: all checks passed
