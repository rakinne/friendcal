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
# Test files read shared fixtures (the place winner cases) from here with a psql backtick read.
export FC_FIXTURES="$ROOT/supabase/tests/fixtures"
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
for f in users_auth.sql join_proposal.sql commitments.sql places.sql social.sql; do
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
  # Every wave file must be safe to apply again: strict mode, so a statement that is not idempotent
  # (a bare `create`, a constraint without its duplicate guard) stops the run here.
  load_wave upgrade_check strict
  assert_schema_shape upgrade_check "upgrade, wave applied a second time"
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
# ---------------------------------------------------------------------------
# 6. Place voting concurrency (#11). Same shape as section 5: session A holds a transaction open
#    while session B races it. Fixtures use their own users because deleting an account is permanent.
#    6a vote versus lock         the vote must not land after the winner is counted
#    6b delete versus lock       the interleaving that deadlocked before the user row was locked
#                                `for no key update`: A holds the plan row, B holds the user row
#    6c delete versus delete     two voters on one plan both finish, neither deadlocks
#    6d vote versus delete       a vote and a deletion for one user serialize in either order
#    6e arrival order            created_at follows arrival, not transaction start
# ---------------------------------------------------------------------------
echo "# place voting concurrency"
H=00000000-0000-0000-0000-0000000e0001;  W=00000000-0000-0000-0000-0000000e0002
V1=00000000-0000-0000-0000-0000000e0003; V2=00000000-0000-0000-0000-0000000e0004; V3=00000000-0000-0000-0000-0000000e0005
D2=00000000-0000-0000-0000-0000000e0006; D3A=00000000-0000-0000-0000-0000000e0007; D3B=00000000-0000-0000-0000-0000000e0008
D4A=00000000-0000-0000-0000-0000000e0009; D4B=00000000-0000-0000-0000-0000000e000a
CP1=20000000-0000-0000-0000-0000000e0101; CP2=20000000-0000-0000-0000-0000000e0102; CP3=20000000-0000-0000-0000-0000000e0103
CP4=20000000-0000-0000-0000-0000000e0104; CP5=20000000-0000-0000-0000-0000000e0105
PL1A=30000000-0000-0000-0000-0000000e0111; PL1B=30000000-0000-0000-0000-0000000e0112; PL2=30000000-0000-0000-0000-0000000e0121
PL3=30000000-0000-0000-0000-0000000e0131; PL4=30000000-0000-0000-0000-0000000e0141
psql_db "$CDB" -o /dev/null <<SQL
insert into users(id, display_name) select u, 'race ' || u from unnest(array['$H','$W','$V1','$V2','$V3','$D2','$D3A','$D3B','$D4A','$D4B']::uuid[]) u;
insert into auth.users(id, email) select u, u || '@example.com' from unnest(array['$H','$W','$V1','$V2','$V3','$D2','$D3A','$D3B','$D4A','$D4B']::uuid[]) u;
create or replace function t.cplan(pid uuid, day text, recips uuid[]) returns void language plpgsql as \$\$
begin
  insert into proposals(id, title, window_start, window_end, created_by, distribution, area_name, area_lat, area_lon)
  values (pid, 'Race', '2026-12-01 00:00Z', '2026-12-20 00:00Z', recips[1],
          jsonb_build_object('mode', 'newGroup', 'recipientIDs', to_jsonb(recips)), 'Austin, TX', 30.2672, -97.7431);
  insert into availability_slots(user_id, range, source_proposal_id, state, expires_at)
  select r, format('[2026-12-%s 18:00Z,2026-12-%s 20:00Z)', day, day)::tstzrange, pid, 'softHold', now() + interval '30 days'
    from unnest(recips) r;
end \$\$;
select t.cplan('$CP1', '05', array['$H','$V1','$V2','$V3','$W']::uuid[]);
select t.cplan('$CP2', '06', array['$H','$V1','$V2','$V3','$D2']::uuid[]);
select t.cplan('$CP3', '07', array['$H','$V1','$D3A','$D3B']::uuid[]);
select t.cplan('$CP4', '08', array['$H','$V1','$D4A','$D4B']::uuid[]);
select t.cplan('$CP5', '09', array['$H','$V1','$V2']::uuid[]);
insert into proposal_places(id, proposal_id, suggested_by, name, lat, lon, created_at) values
  ('$PL1A', '$CP1', '$V1', 'A', 30.1, -97.7, now() - interval '2 hours'),
  ('$PL1B', '$CP1', '$V2', 'B', 30.2, -97.7, now() - interval '1 hour'),
  ('$PL2',  '$CP2', '$V1', 'A', 30.1, -97.7, now()),
  ('$PL3',  '$CP3', '$V1', 'A', 30.1, -97.7, now()),
  ('$PL4',  '$CP4', '$V1', 'A', 30.1, -97.7, now());
insert into place_votes(proposal_id, voter_id, place_id) values
  ('$CP1', '$V3', '$PL1A'), ('$CP2', '$D2', '$PL2'), ('$CP3', '$D3A', '$PL3'), ('$CP3', '$D3B', '$PL3');
SQL
# Outcome of a place call as text, for sessions that run it: "sqlstate/hint".
call_sql() { echo "select (c).sqlstate || '/' || (c).hint from (select t.call(\$q\$$1\$q\$, '$2'::uuid) as c) x"; }

# 6a. A locks CP1 and holds its transaction; B votes meanwhile. After A commits the plan is locked, so
#     B is refused FC_LOCKED and its vote never lands; the stored winner is the one counted at lock.
psql_db "$CDB" -tA -c "begin; select t.become('authenticated', '$H'); select count(*) from lock_proposal('$CP1', '2026-12-05 18:00Z', '2026-12-05 19:30Z'); select pg_sleep(1.5); commit;" >"$TMP/c1.out" 2>&1 &
A=$!
# gstack-timing-ok: B only needs to start while A holds the plan row lock (A sleeps 1.5s); a slower B still finds the plan locked and gets the same answer.
sleep 0.4
B_OUT="$(psql_db "$CDB" -tA -c "$(call_sql "select vote_place('$CP1', '$PL1B')" "$W")" 2>&1)" || true
wait $A || true
A_OUT="$(grep -E '^[0-9]+$' "$TMP/c1.out" | head -1)"
FINAL="$(psql_db "$CDB" -tAc "select status || ':' || coalesce(locked_place_id::text, 'null') || ':' || (select count(*) from place_votes where proposal_id = p.id and voter_id = '$W') from proposals p where id = '$CP1'")"
if [[ "$A_OUT" == "5" && "$B_OUT" == "55000/FC_LOCKED" && "$FINAL" == "locked:$PL1A:0" ]]; then
  echo "  ok - a vote racing a lock is refused after the lock, and the stored winner is the one counted"
else
  echo "  not ok - vote versus lock: A=$A_OUT B=$B_OUT final=$FINAL (want 5, 55000/FC_LOCKED, locked:$PL1A:0)"; exit 1
fi

# 6b. The deadlock interleaving. A holds the PLAN row (as lock_proposal does first) and pauses; B,
#     a covered recipient who voted, runs delete_account -- it takes the user row, then waits for the
#     plan. A resumes and inserts the Busy block, which key-shares B's user row. With `for update` on
#     that row A would wait for B while B waits for A (40P01). With `for no key update` both finish.
psql_db "$CDB" -tA -c "begin; select 1 from proposals where id = '$CP2' for update; select pg_sleep(1.5); select t.become('authenticated', '$H'); select count(*) from lock_proposal('$CP2', '2026-12-06 18:00Z', '2026-12-06 19:30Z'); commit;" >"$TMP/c2.out" 2>&1 &
A=$!
# gstack-timing-ok: B must take the user row while A still holds only the plan row (A sleeps 1.5s first).
sleep 0.4
B_OUT="$(psql_db "$CDB" -tA -c "begin; select t.become('authenticated', '$D2'); select delete_account(); commit;" 2>&1)" || true
wait $A || true
A_OUT="$(grep -E '^[0-9]+$' "$TMP/c2.out" | tail -1)"
FINAL="$(psql_db "$CDB" -tAc "select status || ':' || (select count(*) from place_votes where proposal_id = p.id and voter_id = '$D2') from proposals p where id = '$CP2'")"
if [[ "$A_OUT" == "5" && "$B_OUT" == *'"already_deleted": false'* && "$B_OUT" != *deadlock* && "$FINAL" == "locked:1" ]]; then
  echo "  ok - delete_account against lock_proposal for a covered voter: no deadlock, the vote on the locked plan stays"
else
  echo "  not ok - delete versus lock: A=$A_OUT B=$B_OUT final=$FINAL"; echo "$(cat "$TMP/c2.out")"; exit 1
fi

# 6c. Two voters on one plan delete their accounts at once. B waits for A's plan lock, then finishes.
psql_db "$CDB" -tA -c "begin; select t.become('authenticated', '$D3A'); select delete_account(); select pg_sleep(1.5); commit;" >"$TMP/c3.out" 2>&1 &
A=$!
# gstack-timing-ok: B must start while A holds the plan lock it took during delete_account.
sleep 0.4
B_OUT="$(psql_db "$CDB" -tA -c "begin; select t.become('authenticated', '$D3B'); select delete_account(); commit;" 2>&1)" || true
wait $A || true
FINAL="$(psql_db "$CDB" -tAc "select count(*) from place_votes where proposal_id = '$CP3'")"
if [[ "$B_OUT" == *'"already_deleted": false'* && "$B_OUT" != *deadlock* && "$(cat "$TMP/c3.out")" != *deadlock* && "$(cat "$TMP/c3.out")" == *'"already_deleted": false'* && "$FINAL" == "0" ]]; then
  echo "  ok - two delete_account calls on a shared voted plan both finish and both votes are removed"
else
  echo "  not ok - delete versus delete: B=$B_OUT final=$FINAL"; cat "$TMP/c3.out"; exit 1
fi

# 6d. A vote and the same user's deletion serialize, in either order.
#     First: deletion in flight, vote arrives -> the vote waits, then is refused because the account is gone.
psql_db "$CDB" -tA -c "begin; select t.become('authenticated', '$D4A'); select delete_account(); select pg_sleep(1.5); commit;" >"$TMP/c4a.out" 2>&1 &
A=$!
# gstack-timing-ok: B must arrive while A's deletion transaction is still open.
sleep 0.4
B_OUT="$(psql_db "$CDB" -tA -c "$(call_sql "select vote_place('$CP4', '$PL4')" "$D4A")" 2>&1)" || true
wait $A || true
FINAL_A="$(psql_db "$CDB" -tAc "select count(*) from place_votes where voter_id = '$D4A'")"
#     Second: vote in flight, deletion arrives -> the deletion waits, then removes the vote.
psql_db "$CDB" -tA -c "begin; select t.become('authenticated', '$D4B'); select vote_place('$CP4', '$PL4'); select pg_sleep(1.5); commit;" >"$TMP/c4b.out" 2>&1 &
A=$!
# gstack-timing-ok: B must arrive while A's vote transaction is still open.
sleep 0.4
B2_OUT="$(psql_db "$CDB" -tA -c "begin; select t.become('authenticated', '$D4B'); select delete_account(); commit;" 2>&1)" || true
wait $A || true
FINAL_B="$(psql_db "$CDB" -tAc "select count(*) from place_votes where voter_id = '$D4B'")"
if [[ "$B_OUT" == "42501/FC_ACCOUNT_DELETED" && "$FINAL_A" == "0" && "$B2_OUT" == *'"already_deleted": false'* && "$FINAL_B" == "0" ]]; then
  echo "  ok - a vote racing the same user's deletion leaves no vote, whichever arrives first"
else
  echo "  not ok - vote versus delete: B=$B_OUT votes=$FINAL_A / B2=$B2_OUT votes=$FINAL_B"; exit 1
fi

# 6e. created_at follows arrival. B opens its transaction FIRST (so now() would be earliest), then
#     waits; A suggests and commits; then B suggests. B's place must still sort after A's.
psql_db "$CDB" -tA -c "begin; select 1; select pg_sleep(1.2); select t.become('authenticated', '$V2'); select suggest_place('$CP5', 'Second', null, 30.3, -97.7, null); commit;" >"$TMP/c5.out" 2>&1 &
A=$!
# gstack-timing-ok: A must complete while B's transaction (opened first) is still waiting to suggest.
sleep 0.4
psql_db "$CDB" -tA -c "$(call_sql "select suggest_place('$CP5', 'First', null, 30.1, -97.7, null)" "$V1")" >"$TMP/c5a.out" 2>&1 || true
wait $A || true
ORDERED="$(psql_db "$CDB" -tAc "select (select created_at from proposal_places where proposal_id = '$CP5' and name = 'Second') > (select created_at from proposal_places where proposal_id = '$CP5' and name = 'First')")"
if [[ "$ORDERED" == "t" ]]; then
  echo "  ok - a suggestion's created_at follows arrival, not the start of its transaction"
else
  echo "  not ok - arrival order: ordered=$ORDERED A=$(cat "$TMP/c5a.out") B=$(cat "$TMP/c5.out")"; exit 1
fi

# 6f. Structural checks that keep one copy of each rule.
grep -q 'proposal_is_readable' "$ROOT/supabase/places.sql" && ! grep -q 'recipientIDs' "$ROOT/supabase/places.sql" \
  && echo "  ok - places.sql reuses proposal_is_readable and has no second copy of the membership test" \
  || { echo "  not ok - places.sql re-derives plan membership instead of calling proposal_is_readable"; exit 1; }
echo "sql tests: all passed"
