-- Small assertion helpers. A failed check raises, which stops the run.
create schema if not exists tests;
grant usage on schema tests to public;

create or replace function tests.pass(p_name text) returns void language plpgsql as $$
begin raise notice 'ok   - %', p_name; end $$;

create or replace function tests.ok(p_name text, p_cond boolean) returns void language plpgsql as $$
begin
  if p_cond is distinct from true then raise exception 'FAIL - %', p_name; end if;
  raise notice 'ok   - %', p_name;
end $$;

create or replace function tests.eq(p_name text, p_actual anyelement, p_expected anyelement) returns void language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'FAIL - %: expected %, got %', p_name, p_expected, p_actual;
  end if;
  raise notice 'ok   - %', p_name;
end $$;

-- Run a statement expecting it to fail with a given SQLSTATE.
create or replace function tests.throws(p_name text, p_sql text, p_state text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlstate = p_state then raise notice 'ok   - %', p_name; return; end if;
    raise exception 'FAIL - %: expected SQLSTATE %, got % (%)', p_name, p_state, sqlstate, sqlerrm;
  end;
  raise exception 'FAIL - %: expected an error but it succeeded', p_name;
end $$;

-- Act as a signed-in member, as the API does: the "authenticated" role plus
-- the JWT claims that auth.uid() reads.
create or replace function tests.login(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $$;

create or replace function tests.anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  execute 'set local role anon';
end $$;

create or replace function tests.logout() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  execute 'reset role';
end $$;

-- Make a member the way sign-up does: an auth user, then a profile.
create or replace function tests.member(p_name text, p_email text default null) returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into auth.users (email) values (coalesce(p_email, lower(p_name) || '@example.test')) returning id into v_id;
  perform tests.login(v_id);
  perform public.upsert_my_profile(p_name, null, 'sage');
  perform tests.logout();
  return v_id;
end $$;

create or replace function tests.staff(p_name text) returns uuid language plpgsql as $$
declare v_id uuid := tests.member(p_name);
begin
  insert into public.staff (user_id) values (v_id);
  return v_id;
end $$;

-- A class that is open for check-in right now. Returns its code.
create or replace function tests.open_class(p_type text default 'mat_pilates', p_starts timestamptz default now()) returns text language plpgsql as $$
declare v jsonb; v_staff uuid;
begin
  select user_id into v_staff from public.staff limit 1;
  if v_staff is null then v_staff := tests.staff('Frontdesk'); end if;
  perform tests.login(v_staff);
  v := public.staff_create_class(p_type, p_starts, 50, 'Test Instructor', 12);
  perform tests.logout();
  return v ->> 'code';
end $$;

-- Look a test member up by first name, and act as them.
create or replace function tests.uid(p_name text) returns uuid language sql stable security definer set search_path = '' as $$
  select id from auth.users where email = lower(p_name) || '@example.test'
$$;
create or replace function tests.as_member(p_name text) returns void language sql as $$
  select tests.login(tests.uid(p_name))
$$;

-- A past check-in written straight into the tables, for history and streak
-- tests. (The real route, check_in(), only works inside a class's window.)
create or replace function tests.raw_checkin(p_member uuid, p_at timestamptz) returns void language plpgsql as $$
declare v_class uuid;
begin
  insert into public.classes (class_type, starts_at, duration_min, instructor)
  values ('mat_pilates', p_at, 50, 'History') returning id into v_class;
  insert into public.class_codes (class_id, code) values (v_class, public._new_code());
  insert into public.checkins (member_id, class_id, checked_in_at) values (p_member, v_class, p_at);
end $$;
