#!/usr/bin/env bash
# Runs the Supabase SQL tests against a throwaway local Postgres (15+; security_invoker views, which
# the stealth boundary depends on, do not exist on 14):
#   1. new project: Supabase stand-ins, schema.sql, then lock_proposal.sql twice (it must be idempotent)
#   2. rls.sql in BOTH load modes -- statement-by-statement (what the Supabase SQL editor does) and
#      --single-transaction -- asserting the same policy count in each, plus security_invoker on views
#   3. upgrade: this wave's SQL on top of origin/main's schema.sql with rows ALREADY PRESENT
#   4. supabase/tests/*_test.sql, each in its own database, against a fresh schema and the upgraded one
#   5. two-session concurrency checks for lock_proposal
# The server listens only on a Unix socket in a private (0700) temp dir, never on TCP, so the
# trust-auth superuser is reachable by this OS user alone. Cleans up on exit.
#
# Every assertion that is about RLS runs under `set local role authenticated`/`anon` via the t.*
# helpers: this script connects as `postgres`, which is rolsuper=t rolbypassrls=t and bypasses RLS
# unconditionally, so an assertion made as postgres would pass against a deny-all policy.
#
# Usage: scripts/test-sql.sh        (PG_BIN overrides the Postgres bin directory)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PG_BIN="${PG_BIN:-}"
if [[ -z "$PG_BIN" ]]; then
  for d in /opt/homebrew/opt/postgresql@17/bin /opt/homebrew/opt/postgresql@16/bin /opt/homebrew/opt/postgresql@15/bin \
           /usr/lib/postgresql/18/bin /usr/lib/postgresql/17/bin /usr/lib/postgresql/16/bin /usr/lib/postgresql/15/bin; do
    [[ -x "$d/initdb" ]] && { PG_BIN="$d"; break; }
  done
fi
if [[ -z "$PG_BIN" ]]; then
  PG_BIN="$(dirname "$(command -v initdb 2>/dev/null || echo /nonexistent/initdb)")"
fi
[[ -x "$PG_BIN/initdb" ]] || { echo "error: Postgres 15+ not found; set PG_BIN" >&2; exit 1; }
PG_MAJOR="$("$PG_BIN/initdb" --version | sed -E 's/.* ([0-9]+)[.0-9]*.*/\1/')"
[[ "$PG_MAJOR" -ge 15 ]] || {
  echo "error: Postgres $PG_MAJOR found at $PG_BIN, but 15+ is required (security_invoker views); set PG_BIN" >&2
  exit 1
}

# Short path under /tmp: a Unix socket path must stay under ~100 bytes.
TMP="$(mktemp -d /tmp/fcpg.XXXXXX)"
chmod 700 "$TMP"
cleanup() { "$PG_BIN/pg_ctl" -D "$TMP/data" stop -m immediate >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT

"$PG_BIN/initdb" -D "$TMP/data" -U postgres -A trust >/dev/null
"$PG_BIN/pg_ctl" -D "$TMP/data" -l "$TMP/pg.log" -w -o "-k $TMP -c listen_addresses=''" start >/dev/null

# Pin the session timezone for every connection. Without this, any assertion that renders a
# timestamptz as text compares against the developer's local zone, so it passes in UTC and fails in
# America/Los_Angeles -- a failure that looks like a logic bug and is only ever a formatting one.
export PGTZ=UTC

psql_db() { local db="$1"; shift; "$PG_BIN/psql" -h "$TMP" -U postgres -d "$db" -X -q -v ON_ERROR_STOP=1 "$@"; }
# Statement-by-statement, errors tolerated: what pasting a file into the Supabase SQL editor does.
psql_loose() { local db="$1"; shift; "$PG_BIN/psql" -h "$TMP" -U postgres -d "$db" -X -q -v ON_ERROR_STOP=0 "$@"; }
quiet() { grep -v 'NOTICE' || true; }
newdb() { psql_db postgres -c "create database $1" >/dev/null; }

# Every .sql file this wave adds, in application order, after schema.sql. Each must be idempotent.
# schema_additions.sql comes first: every policy, view and function after it may assume its columns.
WAVE_SQL=(schema_additions.sql lock_proposal.sql rls.sql)
for f in users_auth.sql join_proposal.sql commitments.sql; do
  [[ -f "$ROOT/supabase/$f" ]] && WAVE_SQL+=("$f")
done

# The expected counts are derived from the SQL files themselves -- the number of `create policy` and
# `create view` statements across the wave -- so there is no hand-maintained constant to drift
# (eng review red flag 8: the project's worst structural risk is hand-synced lists).
wave_paths() { local f; for f in "${WAVE_SQL[@]}"; do echo "$ROOT/supabase/$f"; done; }
# shellcheck disable=SC2046
EXPECTED_POLICIES="$(grep -chE '^[[:space:]]*create policy' $(wave_paths) | paste -sd+ - | bc)"
# The view invariant is not "some views are security_invoker" but "every view we define is", so this
# counts the create statements and separately requires zero non-invoker views: a view that loses the
# option is caught even when the total still matches.
# shellcheck disable=SC2046
EXPECTED_VIEWS="$(grep -chE '^[[:space:]]*create (or replace )?view' $(wave_paths) | paste -sd+ - | bc)"

# load_wave <db> [loose] -- apply this wave's SQL, then the shared test helpers.
load_wave() {
  local db="$1" mode="${2:-strict}" f
  for f in "${WAVE_SQL[@]}"; do
    if [[ "$mode" == loose ]]; then
      psql_loose "$db" -f "$ROOT/supabase/$f" 2>&1 | quiet
    else
      psql_db "$db" -f "$ROOT/supabase/$f" 2>&1 | quiet
    fi
  done
  psql_db "$db" -f "$ROOT/supabase/tests/helpers.sql" 2>&1 | quiet
}

status=0
fail() { echo "  not ok - $1"; status=1; }

# ---------------------------------------------------------------------------
# 1. New project.
# ---------------------------------------------------------------------------
psql_db postgres -f "$ROOT/supabase/tests/supabase-stubs.sql"
psql_db postgres -f "$ROOT/supabase/schema.sql" 2>&1 | quiet
psql_db postgres -f "$ROOT/supabase/lock_proposal.sql" 2>&1 | quiet
psql_db postgres -f "$ROOT/supabase/lock_proposal.sql" 2>&1 | quiet
echo "ok - lock_proposal.sql applies twice on a new project"

# ---------------------------------------------------------------------------
# 2. rls.sql load modes. schema.sql:2 tells a human to paste these files into the Supabase SQL
#    editor, which runs them statement-by-statement; a cautious operator wraps them in one
#    transaction instead. Both must end with every policy installed.
# ---------------------------------------------------------------------------
echo "# rls.sql load modes (expect $EXPECTED_POLICIES policies, $EXPECTED_VIEWS view(s), all security_invoker)"
count_policies() { psql_db "$1" -tAc "select count(*) from pg_policies where schemaname = 'public'" | tr -d ' '; }
count_views() {
  psql_db "$1" -tAc "select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
                      where c.relkind = 'v' and n.nspname = 'public'" | tr -d ' '
}
# Views in public that are NOT security_invoker. Must be zero: a non-invoker view runs as its owner
# and silently hands every caller rows the base table's RLS would have withheld.
count_leaky_views() {
  psql_db "$1" -tAc "select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
                      where c.relkind = 'v' and n.nspname = 'public'
                        and not coalesce(c.reloptions, '{}') @> array['security_invoker=true']" | tr -d ' '
}
# assert_schema_shape <db> <label> -- the policy/view invariants, asserted wherever the wave lands.
assert_schema_shape() {
  local db="$1" label="$2" got got_views leaky
  got="$(count_policies "$db")"
  if [[ "$got" == "$EXPECTED_POLICIES" ]]; then
    echo "  ok - $label: $got/$EXPECTED_POLICIES policies installed"
  else
    fail "$label: $got/$EXPECTED_POLICIES policies installed"
  fi
  got_views="$(count_views "$db")"
  leaky="$(count_leaky_views "$db")"
  if [[ "$got_views" == "$EXPECTED_VIEWS" && "$leaky" == "0" ]]; then
    echo "  ok - $label: $got_views/$EXPECTED_VIEWS view(s), all security_invoker"
  else
    fail "$label: $got_views/$EXPECTED_VIEWS view(s), $leaky not security_invoker"
  fi
}

for mode in statement single-transaction; do
  db="rlsload_${mode//-/_}"
  newdb "$db"
  psql_db "$db" -f "$ROOT/supabase/tests/supabase-stubs.sql" >/dev/null
  psql_db "$db" -f "$ROOT/supabase/schema.sql" 2>&1 | quiet
  # Every wave file is applied in the mode under test, not just rls.sql: an operator pastes the whole
  # run-order into the editor, or wraps the whole run-order in one transaction. Either way the end
  # state must be identical and complete.
  for f in "${WAVE_SQL[@]}"; do
    if [[ "$mode" == statement ]]; then
      psql_loose "$db" -f "$ROOT/supabase/$f" >/dev/null 2>&1
    else
      psql_loose "$db" --single-transaction -f "$ROOT/supabase/$f" >/dev/null 2>&1
    fi
  done
  assert_schema_shape "$db" "$mode"
done

# ---------------------------------------------------------------------------
# 3. Upgrade an existing, POPULATED database built from the base branch's schema.
#    schema.sql is NOT idempotent (7 create table, only circles/circle_members guarded), so the
#    recovery procedure is `git revert` plus the runbook in TODOS.md -- never "re-run the prior SQL".
# ---------------------------------------------------------------------------
echo "# upgrade from origin/main with rows already present"
UPGRADED=""
newdb upgrade_check
psql_db upgrade_check -f "$ROOT/supabase/tests/supabase-stubs.sql" >/dev/null
if git -C "$ROOT" cat-file -e origin/main:supabase/schema.sql 2>/dev/null; then
  git -C "$ROOT" show origin/main:supabase/schema.sql | psql_db upgrade_check 2>&1 | quiet
  psql_db upgrade_check -f "$ROOT/supabase/tests/upgrade_fixture.sql" 2>&1 | quiet
  before="$(psql_db upgrade_check -tAc "select count(*) from users" | tr -d ' ')"
  load_wave upgrade_check loose
  # The wave must install completely on a populated existing database, not only on an empty one.
  assert_schema_shape upgrade_check "upgrade"
  psql_db upgrade_check -tAc "select count(*) from pg_proc where proname = 'lock_proposal'" | grep -qx 1 \
    || fail "lock_proposal is absent after the upgrade"
  after="$(psql_db upgrade_check -tAc "select count(*) from users" | tr -d ' ')"
  if [[ "$before" == "$after" && "$before" != "0" ]]; then
    echo "  ok - this wave's SQL applies over a populated origin/main database ($after pre-existing users kept)"
  else
    fail "pre-existing rows did not survive the upgrade (users: $before -> $after)"
  fi
  # The already-locked plan and its promoted Busy blocks must still be there and still readable.
  psql_db upgrade_check -tAc \
    "select count(*) from proposals where status = 'locked' and locked_end is not null" | grep -qx 1 \
    || fail "the pre-existing locked proposal did not survive the upgrade"
  psql_db upgrade_check -tAc "select count(*) from busy_blocks" | grep -qx 4 \
    || fail "the pre-existing busy_blocks did not survive the upgrade"
  echo "  ok - a pre-existing locked plan, its Busy blocks and a null-expiry hold all survive"
  UPGRADED=upgrade_check
else
  echo "  skip - upgrade check (origin/main:supabase/schema.sql not available)"
fi

# ---------------------------------------------------------------------------
# 4. Test files. Each gets its own database so one file's fixtures cannot be another file's
#    hidden precondition, and so `create schema t` belongs to helpers.sql alone.
#    Every file also runs against the upgraded database, so the wave is tested on both shapes (F9).
# ---------------------------------------------------------------------------
for f in "$ROOT"/supabase/tests/*_test.sql; do
  base="$(basename "$f" .sql)"
  echo "# $(basename "$f") [fresh]"
  newdb "$base"
  psql_db "$base" -f "$ROOT/supabase/tests/supabase-stubs.sql" >/dev/null
  psql_db "$base" -f "$ROOT/supabase/schema.sql" 2>&1 | quiet
  load_wave "$base" loose
  psql_db "$base" -o /dev/null -f "$f" 2>&1 \
    | sed -e 's/^psql:[^:]*:[0-9]*: NOTICE:  /  /' -e 's/^NOTICE:  /  /' || status=1
done

if [[ -n "$UPGRADED" ]]; then
  for f in "$ROOT"/supabase/tests/*_test.sql; do
    base="$(basename "$f" .sql)_upgraded"
    echo "# $(basename "$f") [upgraded]"
    newdb "$base"
    psql_db "$base" -f "$ROOT/supabase/tests/supabase-stubs.sql" >/dev/null
    git -C "$ROOT" show origin/main:supabase/schema.sql | psql_db "$base" 2>&1 | quiet
    psql_db "$base" -f "$ROOT/supabase/tests/upgrade_fixture.sql" 2>&1 | quiet
    load_wave "$base" loose
    psql_db "$base" -o /dev/null -f "$f" 2>&1 \
      | sed -e 's/^psql:[^:]*:[0-9]*: NOTICE:  /  /' -e 's/^NOTICE:  /  /' || status=1
  done
fi

[[ $status -eq 0 ]] || exit $status

# ---------------------------------------------------------------------------
# 5. Concurrency. Session A holds a transaction open while session B races it; B must see A's
#    committed result, never a raw exclusion error (23P01) or stale coverage. Runs in
#    lock_proposal_test's own database, which already holds its t.* helpers and fixtures.
# ---------------------------------------------------------------------------
CDB=lock_proposal_test
echo "# concurrency"
psql_db "$CDB" -o /dev/null <<'SQL'
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

# 5a. Two overlapping locks sharing all recipients: A locks P7 (5 of 5) and holds its transaction;
#     B locks P8 meanwhile. After A commits everyone is Busy, so B must refuse on quorum (22023).
psql_db "$CDB" -tA -c "begin; select t.lock('20000000-0000-0000-0000-000000000007', '2026-11-28 18:00Z', '2026-11-28 19:30Z', t.u(1)); select pg_sleep(1.5); commit;" >"$TMP/a.out" 2>&1 &
A=$!
# gstack-timing-ok: B only needs to start while A holds its transaction open (A sleeps 1.5s); a slow B still sees A committed and gets the same answer.
sleep 0.4
B_OUT="$(psql_db "$CDB" -tA -c "select t.lock('20000000-0000-0000-0000-000000000008', '2026-11-28 19:00Z', '2026-11-28 20:30Z', t.u(1))" 2>&1)"
wait $A
A_OUT="$(grep -E '^(locked:|[0-9A-Z]{5}$)' "$TMP/a.out" | head -1)"
if [[ "$A_OUT" == "locked:5" && "$B_OUT" == "22023" ]]; then
  echo "  ok - overlapping concurrent locks: first locks, second refuses on quorum (no 23P01)"
else
  echo "  not ok - overlapping concurrent locks: A=$A_OUT B=$B_OUT (want locked:5 and 22023)"; exit 1
fi

# 5b. A shrinks u2 and u3's P9 holds below the window and holds its transaction; B locks P9 meanwhile.
#     B must count the edited holds (3 of 5 = 60%) and refuse, not book the withdrawn time.
psql_db "$CDB" -tA -c "begin; update availability_slots set range = '[2026-11-29 20:00Z,2026-11-29 21:00Z)' where source_proposal_id = '20000000-0000-0000-0000-000000000009' and user_id in (t.u(2), t.u(3)); select pg_sleep(1.5); commit;" >"$TMP/a2.out" 2>&1 &
A=$!
# gstack-timing-ok: same ordering as 5a; B must start while A's edit is uncommitted.
sleep 0.4
B_OUT="$(psql_db "$CDB" -tA -c "select t.lock('20000000-0000-0000-0000-000000000009', '2026-11-29 18:00Z', '2026-11-29 19:30Z', t.u(1))" 2>&1)"
wait $A
if [[ "$B_OUT" == "22023" ]]; then
  echo "  ok - a hold edited during a lock is counted as edited (no stale booking)"
else
  echo "  not ok - hold edited during a lock: B=$B_OUT (want 22023)"; exit 1
fi
echo "sql tests: all passed"
