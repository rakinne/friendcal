#!/usr/bin/env bash
# Runs supabase/tests/*_test.sql against a throwaway local Postgres (14+ for range_agg):
# initdb in a temp dir, TCP on 127.0.0.1 (scratch paths can exceed the Unix-socket limit),
# Supabase stand-ins, schema.sql, then each test file. Cleans up on exit.
#
# Usage: scripts/test-sql.sh        (PG_BIN overrides the Postgres bin directory)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PG_BIN="${PG_BIN:-}"
if [[ -z "$PG_BIN" ]]; then
  for d in /opt/homebrew/opt/postgresql@17/bin /opt/homebrew/opt/postgresql@16/bin /opt/homebrew/opt/postgresql@15/bin /opt/homebrew/opt/postgresql@14/bin; do
    [[ -x "$d/initdb" ]] && { PG_BIN="$d"; break; }
  done
fi
if [[ -z "$PG_BIN" ]]; then
  PG_BIN="$(dirname "$(command -v initdb 2>/dev/null || echo /nonexistent/initdb)")"
fi
[[ -x "$PG_BIN/initdb" ]] || { echo "error: Postgres 14+ not found; set PG_BIN" >&2; exit 1; }

TMP="$(mktemp -d)"
PORT=$((55000 + RANDOM % 1000))
cleanup() { "$PG_BIN/pg_ctl" -D "$TMP/data" stop -m immediate >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT

"$PG_BIN/initdb" -D "$TMP/data" -U postgres -A trust >/dev/null
"$PG_BIN/pg_ctl" -D "$TMP/data" -l "$TMP/pg.log" -w -o "-p $PORT -k '' -c listen_addresses=127.0.0.1" start >/dev/null

psql_run() { "$PG_BIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -X -q -v ON_ERROR_STOP=1 "$@"; }
psql_run -f "$ROOT/supabase/tests/supabase-stubs.sql"
psql_run -f "$ROOT/supabase/schema.sql" 2>&1 | { grep -v '^psql:.*NOTICE' || true; }

status=0
for f in "$ROOT"/supabase/tests/*_test.sql; do
  echo "# $(basename "$f")"
  psql_run -o /dev/null -f "$f" 2>&1 | sed -e 's/^psql:[^:]*:[0-9]*: NOTICE:  /  /' -e 's/^NOTICE:  /  /' || status=1
done
exit $status
