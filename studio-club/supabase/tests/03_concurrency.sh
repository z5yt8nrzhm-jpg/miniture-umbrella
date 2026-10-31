#!/usr/bin/env bash
# Hammers the club with many phones at once and checks the answers stay exact.
# Each pgbench client is one phone: it signs in as a member, makes one call in
# its own transaction (the way the API does), and a log records what came back.
set -euo pipefail
cd "$(dirname "$0")"
DB="${1:-club_test}"
Q() { psql -X -q -At -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
PASSED=0
check() {                       # check "name" "sql that returns true"
  local out; out=$(Q -c "$2")
  if [[ "$out" == "t" ]]; then echo "ok   - $1"; PASSED=$((PASSED+1)); else echo "FAIL - $1 (got: $out)"; exit 1; fi
}
bench() {                       # bench <clients> <transactions-per-client> <script>
  local out; out=$(pgbench -n -r -c "$1" -j "$(( $1 < 8 ? $1 : 8 ))" -t "$2" -f "$3" "$DB" 2>&1) || { echo "$out"; echo "FAIL - pgbench aborted"; exit 1; }
  if grep -qiE "aborted|deadlock|error" <<<"$out"; then echo "$out"; echo "FAIL - a client hit an error"; exit 1; fi
  echo "     $(grep -E '^tps' <<<"$out" | sed 's/ (without.*//') | $(grep -E '^latency average' <<<"$out" | sed 's/latency average = //')"
}

Q <<'SQL'
create table if not exists tests.race_log (member_n int, status text, at timestamptz default now());
grant insert on tests.race_log to authenticated;
SQL

# One phone: sign in as member $N, run a statement, log the answer.
script() {                      # script <file> <member-expr> <log-sql>
  cat > "$1" <<EOS
\\set n $2
begin;
select set_config('request.jwt.claims', json_build_object('sub', u.id, 'role', 'authenticated')::text, true) from tests.load_users u where u.n = :n;
set local role authenticated;
$3
commit;
EOS
}
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# ── 1. a retry storm: 200 members, every one of them tapping again and again ──
echo; echo "-- 1. retry storm: 200 members, 60 phones, 6,000 taps"
Q <<'SQL'
truncate tests.race_log;
create table if not exists tests.load_users (n int primary key, id uuid not null);
truncate tests.load_users;
insert into tests.load_users select g, tests.member('Load' || g, 'load' || g || '@example.test') from generate_series(1, 200) g;
SQL
CODE1=$(Q -c "select tests.open_class()")
script "$TMP/s1.sql" "random(1, 200)" "insert into tests.race_log (member_n, status) select :n, public.check_in('$CODE1') ->> 'status';"
bench 60 100 "$TMP/s1.sql"
check "every tap got a plain answer (no errors, no lock-outs)" \
  "select count(*) = 0 from tests.race_log where status not in ('ok','already')"
check "each member was counted exactly once" \
  "select count(*) = 0 from (select member_n from tests.race_log where status = 'ok' group by 1 having count(*) > 1) t"
check "the check-ins in the database match the members who got 'ok'" \
  "select (select count(*) from public.checkins c join tests.load_users u on u.id = c.member_id) = (select count(*) from tests.race_log where status = 'ok')"
check "every member who tapped has exactly one badge" \
  "select count(*) = 0 from tests.load_users u where exists (select 1 from tests.race_log l where l.member_n = u.n) and (select count(*) from public.member_badges b where b.member_id = u.id) <> 1"
check "the repeats were reported as 'already'" \
  "select count(*) filter (where status = 'already') > 5000 from tests.race_log"

# ── 2. one person double-tapping furiously ────────────────────────────────
echo; echo "-- 2. one member, 40 phones' worth of taps on the same class"
Q <<'SQL'
truncate tests.race_log; truncate tests.load_users;
insert into tests.load_users values (1, tests.member('Solo', 'solo@example.test'));
SQL
CODE2=$(Q -c "select tests.open_class()")
script "$TMP/s2.sql" "1" "insert into tests.race_log (member_n, status) select :n, public.check_in('$CODE2') ->> 'status';"
bench 40 50 "$TMP/s2.sql"
check "one tap won" "select count(*) = 1 from tests.race_log where status = 'ok'"
check "all the other 1,999 were 'already'" "select count(*) = 1999 from tests.race_log where status = 'already'"
check "one check-in row and one badge" \
  "select (select count(*) from public.checkins where member_id = (select id from tests.load_users)) = 1 and (select count(*) from public.member_badges where member_id = (select id from tests.load_users)) = 1"

# ── 3. two classes at once, on the edge of a milestone ────────────────────
echo; echo "-- 3. 100 members on 23 classes, each checking into 2 more at the same moment"
Q <<'SQL'
truncate tests.race_log; truncate tests.load_users;
insert into tests.load_users select g, tests.member('Edge' || g, 'edge' || g || '@example.test') from generate_series(1, 100) g;
do $$ declare u record; i int; begin
  for u in select id from tests.load_users loop
    for i in 1..23 loop perform tests.raw_checkin(u.id, now() - make_interval(weeks => i, hours => 2)); end loop;
  end loop; end $$;
SQL
CODE3A=$(Q -c "select tests.open_class('yoga_flow', now())")
CODE3B=$(Q -c "select tests.open_class('stretch', now() + interval '5 minutes')")
script "$TMP/s3.sql" "random(1, 100)" "insert into tests.race_log (member_n, status) select :n, public.check_in((array['$CODE3A','$CODE3B'])[1 + floor(random() * 2)::int]) ->> 'status';"
bench 60 100 "$TMP/s3.sql"
check "every member reached 25 classes" \
  "select count(*) = 100 from (select c.member_id from public.checkins c join tests.load_users u on u.id = c.member_id group by 1 having count(*) = 25) t"
check "nobody missed the 25-class badge (no lost award)" \
  "select count(*) = 100 from public.member_badges b join tests.load_users u on u.id = b.member_id where b.badge_code = 'classes_25'"
check "nobody missed the free-class perk" \
  "select count(*) = 100 from public.member_perks p join tests.load_users u on u.id = p.member_id where p.perk_code = 'free_class_25'"
check "each member got the perk exactly once" \
  "select count(*) = 0 from (select member_id from public.member_perks group by 1 having count(*) > 1) t"

# ── 4. posting: the hourly limit and retried posts, under a race ──────────
echo; echo "-- 4. the wall: 30 phones posting at once, and one post retried 400 times"
Q <<'SQL'
truncate tests.race_log; truncate tests.load_users;
insert into tests.load_users values (1, tests.member('Poster', 'poster@example.test')), (2, tests.member('Retrier', 'retrier@example.test'));
SQL
script "$TMP/s4a.sql" "1" "insert into tests.race_log (member_n, status) select :n, public.wall_post(gen_random_uuid(), 'a new post') ->> 'status';"
bench 30 10 "$TMP/s4a.sql"
check "the limit of 5 posts an hour held under a race" \
  "select count(*) = 5 from public.wall_posts where author_id = (select id from tests.load_users where n = 1)"
check "the rest were told to wait" "select count(*) = 295 from tests.race_log where status = 'rate_limited'"
RETRY_ID=$(Q -c "select gen_random_uuid()")
script "$TMP/s4b.sql" "2" "insert into tests.race_log (member_n, status) select :n, public.wall_post('$RETRY_ID', 'posted from a bad connection') ->> 'status';"
bench 20 20 "$TMP/s4b.sql"
check "a post retried 400 times appears once" \
  "select count(*) = 1 from public.wall_posts where author_id = (select id from tests.load_users where n = 2)"

# ── 5. the front desk: two staff tapping Redeem on the same perk ──────────
echo; echo "-- 5. 30 staff taps on one perk"
Q <<'SQL'
truncate tests.race_log; truncate tests.load_users;
insert into tests.load_users values (1, tests.staff('Desk1')), (2, tests.member('Winner', 'winner@example.test'));
do $$ declare w uuid := (select id from tests.load_users where n = 2); i int; begin
  for i in 1..25 loop perform tests.raw_checkin(w, now() - make_interval(weeks => i, hours => 3)); end loop;
  perform public._award(w); end $$;
SQL
PERK=$(Q -c "select id from public.member_perks where member_id = (select id from tests.load_users where n = 2) and perk_code = 'free_class_25'")
script "$TMP/s5.sql" "1" "insert into tests.race_log (member_n, status) select :n, public.staff_redeem_perk('$PERK') ->> 'status';"
bench 30 10 "$TMP/s5.sql"
check "exactly one redeem succeeded" "select count(*) = 1 from tests.race_log where status = 'ok'"
check "the other 299 were told it was already redeemed" "select count(*) = 299 from tests.race_log where status = 'already_redeemed'"

# ── 6. signed-out phones: the last spots of an event, and a form tapped again and again ──
echo; echo "-- 6. 400 people, 50 phones, 2,000 taps on an event with 10 spots"
Q <<'SQL'
truncate tests.race_log;
grant insert on tests.race_log to anon;
select tests.staff('Desk6') \g /dev/null
SQL
EV=$(Q -c "insert into public.events (title, starts_at, spots, published) values ('Race night', now() + interval '2 days', 10, true) returning id")
cat > "$TMP/s6.sql" <<EOS
\\set n random(1, 400)
begin;
set local role anon;
insert into tests.race_log (member_n, status) select :n, public.event_signup(gen_random_uuid(), '$EV', 'Person ' || :n, 'p' || :n || '@example.test') ->> 'status';
commit;
EOS
bench 50 40 "$TMP/s6.sql"
check "every tap got a plain answer" "select count(*) = 0 from tests.race_log where status not in ('ok', 'full')"
check "exactly 10 people hold the 10 spots" "select count(*) = 10 from public.leads where event_id = '$EV' and kind = 'event_signup'"
check "nobody holds a spot twice" "select count(*) = 0 from (select contact_norm from public.leads where event_id = '$EV' group by 1 having count(*) > 1) t"
check "the public list shows no spots left" "select (public.public_events() -> 0 ->> 'spots_left')::int = 0"

echo; echo "-- 7. one form tapped 400 times, and one contact sending 300 different forms at once"
Q <<'SQL'
truncate tests.race_log;
SQL
SAME=$(Q -c "select gen_random_uuid()")
cat > "$TMP/s7a.sql" <<EOS
\\set n 1
begin;
set local role anon;
insert into tests.race_log (member_n, status) select :n, public.submit_form('$SAME', 'signup', 'Retry Rita', 'rita@example.test', '{}') ->> 'status';
commit;
EOS
bench 20 20 "$TMP/s7a.sql"
check "a form tapped 400 times is stored once" "select count(*) = 1 from public.leads where contact_norm = 'rita@example.test'"
check "every one of those taps was told ok" "select count(*) = 400 from tests.race_log where status = 'ok'"
Q -c "truncate tests.race_log"
cat > "$TMP/s7b.sql" <<EOS
\\set n 2
begin;
set local role anon;
insert into tests.race_log (member_n, status) select :n, public.submit_form(gen_random_uuid(), 'signup', 'Spammer', 'spam@example.test', '{}') ->> 'status';
commit;
EOS
bench 30 10 "$TMP/s7b.sql"
check "the limit of 5 forms an hour per contact held under a race" "select count(*) = 5 from public.leads where contact_norm = 'spam@example.test'"
check "the other 295 were told to wait" "select count(*) = 295 from tests.race_log where status = 'rate_limited'"

echo; echo "concurrency: $PASSED checks passed"
