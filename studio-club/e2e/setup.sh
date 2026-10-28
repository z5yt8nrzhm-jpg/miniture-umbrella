#!/usr/bin/env bash
# A fresh database for the end-to-end run: the real migrations, plus the demo
# classes (codes MAT222 open now, FLOW33 soon, REST44 finished).
set -euo pipefail
cd "$(dirname "$0")/../supabase"
DB="${CLUB_E2E_DB:-club_e2e}"
dropdb --if-exists --force "$DB" 2>/dev/null || true
createdb "$DB"
psql -X -q -v ON_ERROR_STOP=1 -d "$DB" -f tests/shim.sql
for f in migrations/*.sql seed.sql; do psql -X -q -v ON_ERROR_STOP=1 -d "$DB" -f "$f"; done
echo "database $DB ready"
