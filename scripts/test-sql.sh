#!/usr/bin/env bash
# Runs the Supabase SQL tests against a throwaway local Postgres (14+ for range_agg):
#   1. new project: Supabase stand-ins, schema.sql, then lock_proposal.sql twice (it must be idempotent)
#   2. upgrade: lock_proposal.sql on top of origin/main's schema.sql (an existing database)
#   3. supabase/tests/*_test.sql
#   4. two-session concurrency checks for lock_proposal
# The server listens only on a Unix socket in a private (0700) temp dir, never on TCP, so the
# trust-auth superuser is reachable by this OS user alone. Cleans up on exit.
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

# Short path under /tmp: a Unix socket path must stay under ~100 bytes.
TMP="$(mktemp -d /tmp/fcpg.XXXXXX)"
chmod 700 "$TMP"
cleanup() { "$PG_BIN/pg_ctl" -D "$TMP/data" stop -m immediate >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT

"$PG_BIN/initdb" -D "$TMP/data" -U postgres -A trust >/dev/null
"$PG_BIN/pg_ctl" -D "$TMP/data" -l "$TMP/pg.log" -w -o "-k $TMP -c listen_addresses=''" start >/dev/null

psql_db() { local db="$1"; shift; "$PG_BIN/psql" -h "$TMP" -U postgres -d "$db" -X -q -v ON_ERROR_STOP=1 "$@"; }
quiet() { grep -v 'NOTICE' || true; }

# 1. New project.
psql_db postgres -f "$ROOT/supabase/tests/supabase-stubs.sql"
psql_db postgres -f "$ROOT/supabase/schema.sql" 2>&1 | quiet
psql_db postgres -f "$ROOT/supabase/lock_proposal.sql" 2>&1 | quiet
psql_db postgres -f "$ROOT/supabase/lock_proposal.sql" 2>&1 | quiet
echo "ok - lock_proposal.sql applies twice on a new project"

# 2. Upgrade an existing database built from the base branch's schema.
psql_db postgres -c "create database upgrade_check" >/dev/null
psql_db upgrade_check -f "$ROOT/supabase/tests/supabase-stubs.sql" 2>&1 | quiet
if git -C "$ROOT" cat-file -e origin/main:supabase/schema.sql 2>/dev/null; then
  git -C "$ROOT" show origin/main:supabase/schema.sql | psql_db upgrade_check 2>&1 | quiet
  psql_db upgrade_check -f "$ROOT/supabase/lock_proposal.sql" 2>&1 | quiet
  psql_db upgrade_check -tAc "select count(*) from pg_proc where proname = 'lock_proposal'" | grep -qx 1
  echo "ok - lock_proposal.sql upgrades a database built from origin/main's schema.sql"
else
  echo "skip - upgrade check (origin/main:supabase/schema.sql not available)"
fi

# 3. Test files.
status=0
for f in "$ROOT"/supabase/tests/*_test.sql; do
  echo "# $(basename "$f")"
  psql_db postgres -o /dev/null -f "$f" 2>&1 | sed -e 's/^psql:[^:]*:[0-9]*: NOTICE:  /  /' -e 's/^NOTICE:  /  /' || status=1
done
[[ $status -eq 0 ]] || exit $status

# 4. Concurrency. Session A holds a transaction open while session B races it; B must see A's
#    committed result, never a raw exclusion error (23P01) or stale coverage. Uses the t.* helpers
#    the test file created.
echo "# concurrency"
psql_db postgres -o /dev/null <<'SQL'
-- P7 and P8: same five recipients, overlapping windows on Nov 28; every recipient covers both.
-- P9: five recipients covering Nov 29; A shrinks two holds mid-lock.
insert into proposals(id, title, window_start, window_end, created_by, distribution)
select pid::uuid, 'Race', '2026-11-25 00:00Z', '2026-12-05 00:00Z', t.u(1),
       jsonb_build_object('mode', 'newGroup', 'recipientIDs', jsonb_build_array(t.u(1), t.u(2), t.u(3), t.u(4), t.u(5)))
  from unnest(array['20000000-0000-0000-0000-000000000007', '20000000-0000-0000-0000-000000000008', '20000000-0000-0000-0000-000000000009']) pid;
insert into availability_slots(user_id, range, source_proposal_id, state, expires_at)
select t.u(n), r::tstzrange, pid::uuid, 'softHold', now() + interval '30 days'
  from generate_series(1, 5) n,
       (values ('20000000-0000-0000-0000-000000000007', '[2026-11-28 18:00Z,2026-11-28 21:00Z)'),
               ('20000000-0000-0000-0000-000000000008', '[2026-11-28 18:00Z,2026-11-28 21:00Z)'),
               ('20000000-0000-0000-0000-000000000009', '[2026-11-29 18:00Z,2026-11-29 21:00Z)')) v(pid, r);
SQL

# 4a. Two overlapping locks sharing all recipients: A locks P7 (5 of 5) and holds its transaction;
#     B locks P8 meanwhile. After A commits everyone is Busy, so B must refuse on quorum (22023).
psql_db postgres -tA -c "begin; select t.lock('20000000-0000-0000-0000-000000000007', '2026-11-28 18:00Z', '2026-11-28 19:30Z', t.u(1)); select pg_sleep(1.5); commit;" >"$TMP/a.out" 2>&1 &
A=$!
# gstack-timing-ok: B only needs to start while A holds its transaction open (A sleeps 1.5s); a slow B still sees A committed and gets the same answer.
sleep 0.4
B_OUT="$(psql_db postgres -tA -c "select t.lock('20000000-0000-0000-0000-000000000008', '2026-11-28 19:00Z', '2026-11-28 20:30Z', t.u(1))" 2>&1)"
wait $A
A_OUT="$(grep -E '^(locked:|[0-9A-Z]{5}$)' "$TMP/a.out" | head -1)"
if [[ "$A_OUT" == "locked:5" && "$B_OUT" == "22023" ]]; then
  echo "  ok - overlapping concurrent locks: first locks, second refuses on quorum (no 23P01)"
else
  echo "  not ok - overlapping concurrent locks: A=$A_OUT B=$B_OUT (want locked:5 and 22023)"; exit 1
fi

# 4b. A shrinks u2 and u3's P9 holds below the window and holds its transaction; B locks P9 meanwhile.
#     B must count the edited holds (3 of 5 = 60%) and refuse, not book the withdrawn time.
psql_db postgres -tA -c "begin; update availability_slots set range = '[2026-11-29 20:00Z,2026-11-29 21:00Z)' where source_proposal_id = '20000000-0000-0000-0000-000000000009' and user_id in (t.u(2), t.u(3)); select pg_sleep(1.5); commit;" >"$TMP/a2.out" 2>&1 &
A=$!
# gstack-timing-ok: same ordering as 4a; B must start while A's edit is uncommitted.
sleep 0.4
B_OUT="$(psql_db postgres -tA -c "select t.lock('20000000-0000-0000-0000-000000000009', '2026-11-29 18:00Z', '2026-11-29 19:30Z', t.u(1))" 2>&1)"
wait $A
if [[ "$B_OUT" == "22023" ]]; then
  echo "  ok - a hold edited during a lock is counted as edited (no stale booking)"
else
  echo "  not ok - hold edited during a lock: B=$B_OUT (want 22023)"; exit 1
fi
echo "sql tests: all passed"
