#!/usr/bin/env bash
# Writes the list of database functions the app may call, with their argument
# names, to test/contract/rpc_contract.json. The Flutter tests check the app
# against it, so the app and the database cannot drift apart unnoticed.
# CI regenerates it and fails if the committed copy is out of date.
set -euo pipefail
cd "$(dirname "$0")"
DB="${CLUB_TEST_DB:-club_test}"
OUT="${1:-../../test/contract/rpc_contract.json}"

dropdb --if-exists --force "$DB" 2>/dev/null || true
createdb "$DB"
psql -X -q -v ON_ERROR_STOP=1 -d "$DB" -f shim.sql
for f in ../migrations/*.sql; do psql -X -q -v ON_ERROR_STOP=1 -d "$DB" -f "$f"; done

psql -X -q -At -d "$DB" -c "
  select jsonb_pretty(jsonb_object_agg(p.proname, jsonb_build_object(
           'args',     coalesce(to_jsonb(p.proargnames[1:p.pronargs]), '[]'::jsonb),
           'required', p.pronargs - p.pronargdefaults) order by p.proname))
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prokind = 'f' and has_function_privilege('authenticated', p.oid, 'execute')" > "$OUT"
echo "wrote $OUT ($(grep -c '"args"' "$OUT") functions)"
