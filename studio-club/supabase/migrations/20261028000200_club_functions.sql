-- Gilbert Flex Studio members club: the rules.
--
-- Everything members and staff do goes through these functions. Each one:
--   * runs with a fixed, empty search_path, so nothing can be hijacked;
--   * returns a {"status": ...} answer instead of raising for expected
--     problems (wrong code, rate limit), so the phone can show a plain
--     message instead of an error;
--   * is safe to call twice. A retry after a dropped connection, or a
--     double-tap, changes nothing the second time.

-- Studio tuning knobs, in one place.
--   check-in window   45 min before a class starts to 30 min after it ends
--   daily limit       2 check-ins per member per day
--   wrong codes       8 in 15 minutes, then wait
--   wall posts        5 per hour per member; 3 reports hide a post for review

-- ── internal helpers (not callable from the app) ─────────────────────────
create or replace function public._new_code() returns text
language plpgsql volatile set search_path = ''
as $$
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';   -- no I, O, 0 or 1
  b bytea := decode(replace(gen_random_uuid()::text, '-', ''), 'hex');
  result text := '';
  i int;
begin
  -- bytes 0-5 only: the uuid's version bits sit in later bytes. 256 is a
  -- multiple of 32, so every letter is equally likely.
  for i in 0..5 loop
    result := result || substr(alphabet, (get_byte(b, i) % 32) + 1, 1);
  end loop;
  return result;
end $$;

-- Totals and weekly streaks. A streak is consecutive calendar weeks (Mon-Sun,
-- studio time) with at least one class. It stays alive through the week
-- after the last class, so Monday morning doesn't wipe it.
create or replace function public._stats(p_member uuid, p_now timestamptz default now())
returns jsonb
language sql stable security definer set search_path = ''
as $$
  with wk as (
    select distinct date_trunc('week', c.checked_in_at at time zone public.club_tz())::date as w
    from public.checkins c where c.member_id = p_member
  ),
  g as (select w, w - (row_number() over (order by w))::int * 7 as grp from wk),
  isl as (select count(*)::int as len, max(w) as last_w from g group by grp),
  cur as (select date_trunc('week', p_now at time zone public.club_tz())::date as w)
  select jsonb_build_object(
    'total_classes',    (select count(*) from public.checkins where member_id = p_member),
    'current_streak',   coalesce((select len from isl, cur where isl.last_w >= cur.w - 7
                                  order by isl.last_w desc limit 1), 0),
    'longest_streak',   coalesce((select max(len) from isl), 0),
    'last_checkin_at',  (select max(checked_in_at) from public.checkins where member_id = p_member),
    'classes_this_week',(select count(*) from public.checkins c, cur
                         where c.member_id = p_member
                           and date_trunc('week', c.checked_in_at at time zone public.club_tz())::date = cur.w)
  )
$$;

-- Hand out every badge and perk the member has now earned and doesn't have
-- yet. Safe to run any number of times: already-held ones are skipped.
create or replace function public._award(p_member uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  s jsonb := public._stats(p_member);
  v_total int := (s ->> 'total_classes')::int;
  v_longest int := (s ->> 'longest_streak')::int;
  v_badges jsonb;
  v_perks jsonb;
begin
  with ins as (
    insert into public.member_badges (member_id, badge_code)
    select p_member, b.code from public.badges b
    where (b.kind = 'classes' and v_total >= b.threshold)
       or (b.kind = 'streak'  and v_longest >= b.threshold)
    on conflict do nothing
    returning badge_code
  ) select coalesce(jsonb_agg(badge_code), '[]'::jsonb) into v_badges from ins;

  with ins as (
    insert into public.member_perks (member_id, perk_code)
    select p_member, p.code from public.perks p where v_total >= p.required_classes
    on conflict do nothing
    returning perk_code
  ) select coalesce(jsonb_agg(perk_code), '[]'::jsonb) into v_perks from ins;

  return jsonb_build_object('badges', v_badges, 'perks', v_perks);
end $$;

-- ── members ──────────────────────────────────────────────────────────────
create or replace function public.upsert_my_profile(
  p_name text, p_favorite text default null, p_avatar text default 'sage')
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_name text := btrim(coalesce(p_name, ''));
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if char_length(v_name) not between 1 and 30 then return jsonb_build_object('status', 'invalid_name'); end if;
  if p_avatar is null or p_avatar not in ('sage', 'clay', 'gold', 'sky', 'rose') then
    return jsonb_build_object('status', 'invalid_avatar');
  end if;
  insert into public.profiles (id, display_name, favorite_class, avatar)
  values (v_uid, v_name, nullif(left(btrim(coalesce(p_favorite, '')), 40), ''), p_avatar)
  on conflict (id) do update
    set display_name = excluded.display_name,
        favorite_class = excluded.favorite_class,
        avatar = excluded.avatar;
  return jsonb_build_object('status', 'ok');
end $$;

-- One call for the whole home screen: fewer requests on a weak connection.
create or replace function public.my_stats() returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  p public.profiles%rowtype;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into p from public.profiles where id = v_uid;
  if not found then return jsonb_build_object('has_profile', false); end if;
  return jsonb_build_object(
           'has_profile', true,
           'profile', jsonb_build_object(
             'display_name', p.display_name, 'member_number', p.member_number,
             'avatar', p.avatar, 'favorite_class', p.favorite_class, 'member_since', p.created_at))
      || public._stats(v_uid)
      || jsonb_build_object(
           'badges', (select coalesce(jsonb_agg(jsonb_build_object('code', badge_code, 'earned_at', earned_at)
                                                order by earned_at), '[]'::jsonb)
                      from public.member_badges where member_id = v_uid),
           'perks',  (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'code', perk_code,
                                                                   'earned_at', earned_at, 'redeemed_at', redeemed_at)
                                                order by earned_at), '[]'::jsonb)
                      from public.member_perks where member_id = v_uid));
end $$;

create or replace function public.my_history(p_limit int default 30)
returns table (class_type text, instructor text, starts_at timestamptz, checked_in_at timestamptz)
language sql stable security definer set search_path = ''
as $$
  select c.class_type, c.instructor, c.starts_at, k.checked_in_at
  from public.checkins k join public.classes c on c.id = k.class_id
  where k.member_id = (select auth.uid())
  order by k.checked_in_at desc
  limit least(greatest(coalesce(p_limit, 30), 1), 100)
$$;

-- ── check in ─────────────────────────────────────────────────────────────
-- status: ok | already | invalid | closed | limit | throttled | no_profile
create or replace function public.check_in(p_code text) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_code text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  c public.classes%rowtype;
  v_row uuid;
  v_awards jsonb := jsonb_build_object('badges', '[]'::jsonb, 'perks', '[]'::jsonb);
  v_status text := 'ok';
  v_today date := (now() at time zone public.club_tz())::date;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;

  -- One check-in at a time per member. Two taps, or two phones, queue up
  -- here instead of racing, so counts and awards are always exact.
  perform pg_advisory_xact_lock(hashtextextended('club:' || v_uid::text, 0));

  if not exists (select 1 from public.profiles where id = v_uid) then
    return jsonb_build_object('status', 'no_profile');
  end if;

  delete from public.checkin_attempts where member_id = v_uid and at < now() - interval '1 day';
  if (select count(*) from public.checkin_attempts
      where member_id = v_uid and at > now() - interval '15 minutes') >= 8 then
    return jsonb_build_object('status', 'throttled');
  end if;

  select cl.* into c
  from public.class_codes k join public.classes cl on cl.id = k.class_id
  where k.code = v_code;

  if not found then
    insert into public.checkin_attempts (member_id) values (v_uid);
    return jsonb_build_object('status', 'invalid');
  end if;

  if now() not between c.starts_at - interval '45 minutes'
                   and c.starts_at + make_interval(mins => c.duration_min) + interval '30 minutes' then
    insert into public.checkin_attempts (member_id) values (v_uid);
    return jsonb_build_object('status', 'closed');
  end if;

  if exists (select 1 from public.checkins where member_id = v_uid and class_id = c.id) then
    v_status := 'already';                      -- a retry: report success again, change nothing
  elsif (select count(*) from public.checkins
         where member_id = v_uid
           and (checked_in_at at time zone public.club_tz())::date = v_today) >= 2 then
    return jsonb_build_object('status', 'limit');
  else
    insert into public.checkins (member_id, class_id) values (v_uid, c.id)
    on conflict (member_id, class_id) do nothing returning id into v_row;
    if v_row is null then v_status := 'already'; end if;
    v_awards := public._award(v_uid);
  end if;

  return jsonb_build_object(
    'status', v_status,
    'class', jsonb_build_object('id', c.id, 'class_type', c.class_type,
                                'starts_at', c.starts_at, 'instructor', c.instructor),
    'stats', public._stats(v_uid),
    'new_badges', v_awards -> 'badges',
    'new_perks', v_awards -> 'perks');
end $$;

-- ── the wall ─────────────────────────────────────────────────────────────
-- Newest first, in pages. Pass the last post's created_at and id to get the
-- next page. Members see names and avatars only; nothing else about anyone.
create or replace function public.wall_feed(
  p_before timestamptz default null, p_before_id uuid default null, p_limit int default 20)
returns table (id uuid, author_name text, author_avatar text, body text,
               created_at timestamptz, cheers int, cheered_by_me boolean, is_mine boolean)
language sql stable security definer set search_path = ''
as $$
  select p.id, a.display_name, a.avatar, p.body, p.created_at,
         (select count(*)::int from public.wall_cheers c where c.post_id = p.id),
         exists (select 1 from public.wall_cheers c
                 where c.post_id = p.id and c.member_id = (select auth.uid())),
         p.author_id = (select auth.uid())
  from public.wall_posts p
  join public.profiles a on a.id = p.author_id
  where exists (select 1 from public.profiles me where me.id = (select auth.uid()))
    and not p.hidden
    and (p_before is null
         or (p.created_at, p.id) < (p_before, coalesce(p_before_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)))
  order by p.created_at desc, p.id desc
  limit least(greatest(coalesce(p_limit, 20), 1), 50)
$$;

-- status: ok | invalid_body | invalid | rate_limited | no_profile
-- The phone makes p_client_id once per post and reuses it on every retry.
create or replace function public.wall_post(p_client_id uuid, p_body text) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_body text := btrim(coalesce(p_body, ''));
  v_id uuid;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  perform pg_advisory_xact_lock(hashtextextended('wall:' || v_uid::text, 0));
  if not exists (select 1 from public.profiles where id = v_uid) then
    return jsonb_build_object('status', 'no_profile');
  end if;
  if p_client_id is null then return jsonb_build_object('status', 'invalid'); end if;
  if char_length(v_body) not between 1 and 500 then return jsonb_build_object('status', 'invalid_body'); end if;

  select id into v_id from public.wall_posts where author_id = v_uid and client_id = p_client_id;
  if found then return jsonb_build_object('status', 'ok', 'id', v_id, 'duplicate', true); end if;

  if (select count(*) from public.wall_posts
      where author_id = v_uid and created_at > now() - interval '1 hour') >= 5 then
    return jsonb_build_object('status', 'rate_limited');
  end if;

  insert into public.wall_posts (author_id, client_id, body) values (v_uid, p_client_id, v_body)
  returning id into v_id;
  return jsonb_build_object('status', 'ok', 'id', v_id, 'duplicate', false);
end $$;

-- Sets the cheer on or off, rather than toggling, so a repeat does nothing.
create or replace function public.wall_cheer(p_post uuid, p_on boolean) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_uid uuid := (select auth.uid());
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not exists (select 1 from public.profiles where id = v_uid) then
    return jsonb_build_object('status', 'no_profile');
  end if;
  if coalesce(p_on, true) then
    insert into public.wall_cheers (post_id, member_id)
    select p_post, v_uid where exists (select 1 from public.wall_posts where id = p_post and not hidden)
    on conflict do nothing;
  else
    delete from public.wall_cheers where post_id = p_post and member_id = v_uid;
  end if;
  return jsonb_build_object('status', 'ok',
                            'cheers', (select count(*)::int from public.wall_cheers where post_id = p_post));
end $$;

create or replace function public.wall_report(p_post uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_uid uuid := (select auth.uid());
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not exists (select 1 from public.profiles where id = v_uid) then
    return jsonb_build_object('status', 'no_profile');
  end if;
  insert into public.wall_reports (post_id, reporter_id)
  select p_post, v_uid
  where exists (select 1 from public.wall_posts where id = p_post and author_id <> v_uid)
  on conflict do nothing;
  update public.wall_posts
     set hidden = true, hidden_reason = 'reported'
   where id = p_post and not hidden
     and (select count(*) from public.wall_reports where post_id = p_post) >= 3;
  return jsonb_build_object('status', 'ok');
end $$;

-- App stores require an in-app way to delete an account. This removes the
-- sign-in and, through the foreign keys, everything the member made.
create or replace function public.delete_my_account() returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_uid uuid := (select auth.uid());
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  delete from public.wall_posts where author_id = v_uid;
  delete from auth.users where id = v_uid;
  return jsonb_build_object('status', 'deleted');
end $$;

-- ── staff ────────────────────────────────────────────────────────────────
create or replace function public._require_staff() returns void
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_staff() then raise exception 'not_staff' using errcode = '42501'; end if;
end $$;

create or replace function public.staff_create_class(
  p_class_type text, p_starts_at timestamptz, p_duration_min int,
  p_instructor text, p_capacity int default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_id uuid;
  v_code text;
  v_try int := 0;
begin
  perform public._require_staff();
  if not exists (select 1 from public.class_types where code = p_class_type) then
    return jsonb_build_object('status', 'invalid_class_type');
  end if;
  if p_starts_at is null or p_duration_min is null or p_duration_min not between 15 and 180
     or char_length(btrim(coalesce(p_instructor, ''))) not between 1 and 40
     or (p_capacity is not null and p_capacity not between 1 and 200) then
    return jsonb_build_object('status', 'invalid');
  end if;

  insert into public.classes (class_type, starts_at, duration_min, instructor, capacity, created_by)
  values (p_class_type, p_starts_at, p_duration_min, btrim(p_instructor), p_capacity, (select auth.uid()))
  returning id into v_id;

  loop
    v_code := public._new_code();
    begin
      insert into public.class_codes (class_id, code) values (v_id, v_code);
      exit;
    exception when unique_violation then
      v_try := v_try + 1;
      if v_try >= 10 then raise exception 'could not allocate a check-in code'; end if;
    end;
  end loop;
  return jsonb_build_object('status', 'ok', 'id', v_id, 'code', v_code);
end $$;

-- A day's classes with their codes, for the front-desk screen.
create or replace function public.staff_classes(p_day date default null) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_day date := coalesce(p_day, (now() at time zone public.club_tz())::date);
  v_from timestamptz := (v_day::timestamp) at time zone public.club_tz();
  v_to   timestamptz := ((v_day + 1)::timestamp) at time zone public.club_tz();
begin
  perform public._require_staff();
  return (select coalesce(jsonb_agg(jsonb_build_object(
            'id', c.id, 'class_type', c.class_type, 'starts_at', c.starts_at,
            'duration_min', c.duration_min, 'instructor', c.instructor, 'capacity', c.capacity,
            'code', k.code,
            'checkins', (select count(*) from public.checkins x where x.class_id = c.id))
          order by c.starts_at), '[]'::jsonb)
          from public.classes c join public.class_codes k on k.class_id = c.id
          where c.starts_at >= v_from and c.starts_at < v_to);
end $$;

create or replace function public.staff_member_lookup(p_member_number int) returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare p public.profiles%rowtype;
begin
  perform public._require_staff();
  select * into p from public.profiles where member_number = p_member_number;
  if not found then return jsonb_build_object('status', 'not_found'); end if;
  return jsonb_build_object(
    'status', 'ok',
    'display_name', p.display_name, 'member_number', p.member_number, 'member_since', p.created_at,
    'stats', public._stats(p.id),
    'perks', (select coalesce(jsonb_agg(jsonb_build_object(
                'id', mp.id, 'code', mp.perk_code, 'title', pk.title,
                'earned_at', mp.earned_at, 'redeemed_at', mp.redeemed_at) order by mp.earned_at), '[]'::jsonb)
              from public.member_perks mp join public.perks pk on pk.code = mp.perk_code
              where mp.member_id = p.id));
end $$;

-- status: ok | already_redeemed | not_found. Only one tap can win.
create or replace function public.staff_redeem_perk(p_member_perk uuid) returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_id uuid;
begin
  perform public._require_staff();
  update public.member_perks
     set redeemed_at = now(), redeemed_by = (select auth.uid())
   where id = p_member_perk and redeemed_at is null
  returning id into v_id;
  if v_id is not null then return jsonb_build_object('status', 'ok'); end if;
  if exists (select 1 from public.member_perks where id = p_member_perk) then
    return jsonb_build_object('status', 'already_redeemed');
  end if;
  return jsonb_build_object('status', 'not_found');
end $$;

-- Posts that were reported or hidden, newest first, for moderation.
create or replace function public.staff_flagged_posts() returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
begin
  perform public._require_staff();
  return (select coalesce(jsonb_agg(item order by (item ->> 'created_at') desc), '[]'::jsonb) from (
            select jsonb_build_object(
              'id', p.id, 'author_name', a.display_name, 'body', p.body, 'created_at', p.created_at,
              'hidden', p.hidden, 'hidden_reason', p.hidden_reason,
              'reports', (select count(*) from public.wall_reports r where r.post_id = p.id)) as item
            from public.wall_posts p join public.profiles a on a.id = p.author_id
            where p.hidden or exists (select 1 from public.wall_reports r where r.post_id = p.id)
            order by p.created_at desc limit 50) t);
end $$;

create or replace function public.staff_set_post_hidden(
  p_post uuid, p_hidden boolean, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = ''
as $$
begin
  perform public._require_staff();
  update public.wall_posts
     set hidden = coalesce(p_hidden, true),
         hidden_reason = case when coalesce(p_hidden, true) then coalesce(left(p_reason, 80), 'staff') else null end
   where id = p_post;
  if not found then return jsonb_build_object('status', 'not_found'); end if;
  return jsonb_build_object('status', 'ok');
end $$;

-- ── who may call what ────────────────────────────────────────────────────
-- Postgres gives every function to everyone by default. Take it all back,
-- then hand out exactly the functions the app uses.
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;

grant execute on function
  public.is_staff(),                                 -- used by row level security policies
  public.upsert_my_profile(text, text, text),
  public.my_stats(),
  public.my_history(int),
  public.check_in(text),
  public.wall_feed(timestamptz, uuid, int),
  public.wall_post(uuid, text),
  public.wall_cheer(uuid, boolean),
  public.wall_report(uuid),
  public.delete_my_account(),
  public.staff_create_class(text, timestamptz, int, text, int),
  public.staff_classes(date),
  public.staff_member_lookup(int),
  public.staff_redeem_perk(uuid),
  public.staff_flagged_posts(),
  public.staff_set_post_hidden(uuid, boolean, text)
to authenticated;
