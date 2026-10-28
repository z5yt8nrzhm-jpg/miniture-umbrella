#!/usr/bin/env bash
# A studio years in: thousands of members, a hundred thousand check-ins.
# Times every call a phone makes, checks the queries use their indexes, then
# runs a mixed crowd of phones and reports the slowest responses.
set -euo pipefail
cd "$(dirname "$0")"
DB="${1:-club_test}"
Q() { psql -X -q -At -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
MEMBERS=${VOLUME_MEMBERS:-5000}
CLIENTS=${VOLUME_CLIENTS:-80}
SECONDS_RUN=${VOLUME_SECONDS:-20}
P95_LIMIT_MS=${VOLUME_P95_MS:-250}

echo "-- loading $MEMBERS members and their history"
Q <<SQL
create table if not exists tests.load_users (n int primary key, id uuid not null);
create table if not exists tests.vol_posts (n int primary key, id uuid not null);
truncate tests.load_users, tests.vol_posts;
grant select on tests.vol_posts to authenticated;

with u as (insert into auth.users (email) select 'v' || g || '@example.test' from generate_series(1, $MEMBERS) g returning id, email)
insert into tests.load_users select substring(email from 2 for position('@' in email) - 2)::int, id from u;
insert into public.profiles (id, display_name, avatar)
  select id, 'Member ' || n, (array['sage','clay','gold','sky','rose'])[1 + n % 5] from tests.load_users;

-- 600 classes over the last year, each with a code
insert into public.classes (class_type, starts_at, duration_min, instructor)
  select (array['mat_pilates','yoga_flow','stretch','strength','vibe_pilates','yoga_gentle'])[1 + g % 6],
         now() - (random() * 365) * interval '1 day', 50, 'Instructor ' || (g % 9) from generate_series(1, 600) g;
insert into public.class_codes select id, public._new_code() from public.classes;

-- each member has been to 10 to 59 classes
insert into public.checkins (member_id, class_id, checked_in_at)
  select u.id, c.id, c.starts_at + random() * interval '30 minutes'
  from tests.load_users u
  join lateral (select id, starts_at from public.classes order by random() limit (10 + (u.n * 7919 % 50))) c on true;
select public._award(id) from tests.load_users \g /dev/null

-- 12,000 wall posts over six months, 40,000 cheers, 200 reports
insert into public.wall_posts (author_id, client_id, body, created_at)
  select (select id from tests.load_users where n = 1 + (g * 7 % $MEMBERS)), gen_random_uuid(),
         'Post number ' || g || ': a small win today.', now() - (random() * 180) * interval '1 day'
  from generate_series(1, 12000) g;
insert into tests.vol_posts select row_number() over (order by created_at desc), id from public.wall_posts;
insert into public.wall_cheers (post_id, member_id)
  select (select id from tests.vol_posts where n = 1 + (g * 13 % 12000)), (select id from tests.load_users where n = 1 + (g * 31 % $MEMBERS))
  from generate_series(1, 40000) g on conflict do nothing;
insert into public.wall_reports (post_id, reporter_id)
  select (select id from tests.vol_posts where n = 1 + (g * 61 % 12000)), (select id from tests.load_users where n = 1 + (g * 17 % $MEMBERS))
  from generate_series(1, 200) g on conflict do nothing;
analyze;
SQL
echo "   checkins:    $(Q -c 'select count(*) from public.checkins')"
echo "   wall posts:  $(Q -c 'select count(*) from public.wall_posts')   cheers: $(Q -c 'select count(*) from public.wall_cheers')"
echo "   database:    $(Q -c "select pg_size_pretty(pg_database_size('$DB'))")"

OPEN=$(Q -c "select tests.open_class()")
Q -c "grant select on tests.vol_posts to authenticated" >/dev/null

echo; echo "-- how long each call takes (one signed-in member at a time)"
Q <<'SQL'
create or replace function tests.bench(p_name text, p_sql text, p_iter int, p_max_avg_ms numeric, p_max_ms numeric)
returns void language plpgsql as $$
declare i int; t0 timestamptz; ms numeric; total numeric := 0; worst numeric := 0; m uuid;
begin
  for i in 1..p_iter loop
    select id into m from tests.load_users where n = 1 + (i * 37) % (select count(*) from tests.load_users);
    perform tests.login(m);
    t0 := clock_timestamp();
    execute p_sql;
    ms := extract(epoch from clock_timestamp() - t0) * 1000;
    perform tests.logout();
    total := total + ms; worst := greatest(worst, ms);
  end loop;
  if total / p_iter > p_max_avg_ms or worst > p_max_ms then
    raise exception 'FAIL - %: average % ms, worst % ms (limits % / %)', p_name, round(total / p_iter, 2), round(worst, 2), p_max_avg_ms, p_max_ms;
  end if;
  raise notice 'ok   - %: average % ms, worst % ms', rpad(p_name, 38), lpad(round(total / p_iter, 2)::text, 6), lpad(round(worst, 2)::text, 7);
end $$;
SQL
bench() { # bench "name" "sql" iterations avg-limit-ms worst-limit-ms
  local out; out=$(psql -X -q -At -v ON_ERROR_STOP=1 -d "$DB" -c "select tests.bench('$1', \$q\$$2\$q\$, $3, $4, $5)" 2>&1) || { echo "$out"; exit 1; }
  echo "$out" | sed 's/^psql:.*NOTICE:  //;s/^NOTICE:  //' | grep -E "^ok|FAIL"
}
bench "open the app (my_stats)"          "select public.my_stats()"                                    200  15  80
bench "my class history (30)"            "select count(*) from public.my_history(30)"                  200  15  80
bench "wall, first page (20 posts)"      "select count(*) from public.wall_feed(null, null, 20)"       200  25 120
bench "wall, deep page (6 months back)"  "select count(*) from public.wall_feed(now() - interval '170 days', null, 20)" 200 25 120
bench "post to the wall"                 "select public.wall_post(gen_random_uuid(), 'hello')"          150  20 100
bench "cheer a post"                     "select public.wall_cheer((select id from tests.vol_posts where n = (select 1 + floor(random() * 11999)::int)), true)" 200 15 80
bench "check in (valid code, new member)" "select public.check_in('$OPEN')"                             300  25 120
bench "check in (repeat tap)"            "select public.check_in('$OPEN')"                             300  20 100
bench "check in (wrong code)"            "select public.check_in('NOPE22')"                            100  20 100

echo; echo "-- front desk"
STAFF=$(Q -c "select user_id from public.staff limit 1")
Q <<SQL
do \$\$ declare t0 timestamptz; ms numeric; begin
  perform tests.login('$STAFF');
  t0 := clock_timestamp(); perform public.staff_classes(); ms := extract(epoch from clock_timestamp()-t0)*1000;
  perform tests.ok('front desk: today''s classes ' || round(ms,2) || ' ms', ms < 100);
  t0 := clock_timestamp(); perform public.staff_member_lookup(1500); ms := extract(epoch from clock_timestamp()-t0)*1000;
  perform tests.ok('front desk: member lookup ' || round(ms,2) || ' ms', ms < 100);
  t0 := clock_timestamp(); perform public.staff_flagged_posts(); ms := extract(epoch from clock_timestamp()-t0)*1000;
  perform tests.ok('front desk: flagged posts ' || round(ms,2) || ' ms', ms < 250);
  perform tests.logout();
end \$\$;
SQL

echo; echo "-- the queries use their indexes, not table scans"
explain() { Q -c "explain $1"; }
planck() { # planck "name" "sql" "must-not-match" "must-match"
  local plan; plan=$(explain "$2")
  if grep -qE "$3" <<<"$plan"; then echo "$plan"; echo "FAIL - $1: unexpected scan"; exit 1; fi
  if ! grep -qE "$4" <<<"$plan"; then echo "$plan"; echo "FAIL - $1: expected index not used"; exit 1; fi
  echo "ok   - $1"
}
M=$(Q -c "select id from tests.load_users where n = 77")
planck "wall feed reads the feed index" \
  "select p.id from public.wall_posts p where not p.hidden and (p.created_at, p.id) < (now(), 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid) order by p.created_at desc, p.id desc limit 20" \
  "Seq Scan on wall_posts" "wall_posts_feed"
planck "a member's history uses the member index" \
  "select * from public.checkins where member_id = '$M' order by checked_in_at desc limit 30" \
  "Seq Scan on checkins" "checkins_member_time|checkins_member_id_class_id_key"
planck "a check-in code is found by its unique index" \
  "select class_id from public.class_codes where code = 'ABC234'" \
  "Seq Scan on class_codes" "class_codes_code_key|class_codes_pkey"
planck "cheer counts use the primary key" \
  "select count(*) from public.wall_cheers where post_id = (select id from public.wall_posts limit 1)" \
  "Seq Scan on wall_cheers" "wall_cheers_pkey"
planck "an account delete finds its rows by index" \
  "select 1 from public.checkins where member_id = '$M'" \
  "Seq Scan on checkins" "checkins_member"

echo; echo "-- a crowd: $CLIENTS phones for ${SECONDS_RUN}s, mixed taps"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/mix.sql" <<EOS
\\set r random(1, 100)
\\set n random(1, $MEMBERS)
\\set p random(1, 12000)
begin;
select set_config('request.jwt.claims', json_build_object('sub', u.id, 'role', 'authenticated')::text, true) from tests.load_users u where u.n = :n;
set local role authenticated;
\\if :r <= 35
select public.my_stats();
\\elif :r <= 65
select count(*) from public.wall_feed(null, null, 20);
\\elif :r <= 75
select public.check_in('$OPEN');
\\elif :r <= 85
select public.wall_cheer((select id from tests.vol_posts where n = :p), (:r % 2 = 0));
\\elif :r <= 92
select count(*) from public.my_history(30);
\\elif :r <= 97
select count(*) from public.wall_feed(now() - interval '90 days', null, 20);
\\else
select public.wall_post(gen_random_uuid(), 'a quick note');
\\endif
commit;
EOS
OUT=$(pgbench -n -c "$CLIENTS" -j 4 -T "$SECONDS_RUN" -l --log-prefix "$TMP/log" -f "$TMP/mix.sql" "$DB" 2>&1) || { echo "$OUT"; echo "FAIL - pgbench aborted"; exit 1; }
if grep -qiE "aborted|deadlock|error" <<<"$OUT"; then echo "$OUT"; echo "FAIL - a phone hit an error"; exit 1; fi
TPS=$(grep -E '^tps' <<<"$OUT" | sed 's/ (without.*//;s/tps = //')
DONE=$(grep -E 'number of transactions actually processed' <<<"$OUT" | sed 's/.*: //')
cat "$TMP"/log.* | awk '{print $3}' | sort -n > "$TMP/lat"
N=$(wc -l < "$TMP/lat")
pct() { awk -v n="$N" -v p="$1" 'NR == int(n * p / 100 + 0.999) {printf "%.1f", $1 / 1000}' "$TMP/lat"; }
P50=$(pct 50); P95=$(pct 95); P99=$(pct 99); MAX=$(tail -1 "$TMP/lat" | awk '{printf "%.1f", $1 / 1000}')
echo "   $DONE requests at $TPS requests/second, no errors"
echo "   response time: median $P50 ms, 95% under $P95 ms, 99% under $P99 ms, slowest $MAX ms"
awk -v p="$P95" -v lim="$P95_LIMIT_MS" 'BEGIN { exit !(p + 0 < lim + 0) }' && echo "ok   - 95% of requests answered within ${P95_LIMIT_MS} ms with $CLIENTS phones at once" \
  || { echo "FAIL - 95th percentile $P95 ms is over the ${P95_LIMIT_MS} ms limit"; exit 1; }
echo; echo "volume: all checks passed"
