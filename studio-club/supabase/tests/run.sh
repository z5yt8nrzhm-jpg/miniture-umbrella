#!/usr/bin/env bash
# Builds a fresh test database from the migrations and runs the checks.
#   ./run.sh              everything
#   ./run.sh privacy      one suite (privacy | flows | concurrency | volume)
# Connection comes from the usual PG* variables (PGHOST, PGUSER, ...).
# CLUB_MIGRATIONS_DIR points at another set of migrations (used to prove the
# tests fail when a rule is removed).
set -euo pipefail
cd "$(dirname "$0")"
DB="${CLUB_TEST_DB:-club_test}"
SUITE="${1:-all}"
psql_db() { psql -X -q -v ON_ERROR_STOP=1 -d "$DB" "$@"; }

# Every suite starts from an empty database, so none depends on another.
build() {
  dropdb --if-exists --force "$DB" 2>/dev/null || true
  createdb "$DB"
  psql_db -f shim.sql
  for f in "${CLUB_MIGRATIONS_DIR:-../migrations}"/*.sql; do psql_db -f "$f"; done
  psql_db -f helpers.sql
}

suite() {            # suite <name> <command...>
  local name="$1"; shift
  echo; echo "== $name"
  build
  "$@"
}

[[ "$SUITE" == all || "$SUITE" == privacy ]]     && suite privacy     psql_db -f 01_privacy.sql
[[ "$SUITE" == all || "$SUITE" == flows ]]       && suite flows       psql_db -f 02_flows.sql
[[ "$SUITE" == all || "$SUITE" == concurrency ]] && suite concurrency bash ./03_concurrency.sh "$DB"
[[ "$SUITE" == all || "$SUITE" == volume ]]      && suite volume      bash ./04_volume.sh "$DB"
echo; echo "== all requested suites passed"
