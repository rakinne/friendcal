-- Shared assertion helpers for the SQL lane. `scripts/test-sql.sh` loads this into every test
-- database before the *_test.sql files, so each test file gets `t.*` without redefining it.
-- Idempotent in the lock_proposal.sql sense: safe to re-run.
--
-- The role-switching helpers exist because RLS is invisible to a superuser (eng review T-1).
-- `t.rows`, `t.cols` and `t.call` all run their statement under `set local role <role>` with
-- auth.uid() bound, which is the only way an assertion here means anything.
\set ON_ERROR_STOP 1

create schema if not exists t;

-- t.ok(name, condition): fail loudly or print "ok - name".
create or replace function t.ok(name text, cond boolean) returns void language plpgsql as $$
begin
  if cond is not true then raise exception 'not ok - %', name; end if;
  raise notice 'ok - %', name;
end $$;

-- t.eq(name, actual, expected): like t.ok but reports both sides on failure.
create or replace function t.eq(name text, actual anyelement, expected anyelement) returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'not ok - %: got %, want %', name, coalesce(actual::text, 'NULL'), coalesce(expected::text, 'NULL');
  end if;
  raise notice 'ok - % (%)', name, coalesce(actual::text, 'NULL');
end $$;

-- Fixture user ids u1..u9. Stable and readable in failure output.
create or replace function t.u(n int) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-00000000000' || n)::uuid
$$;

-- Fixture ids whose text contains hex LETTERS. t.u(n) is all digits, so upper(t.u(n)::text) is the same
-- string and a test of "stored in uppercase" built on it proves nothing. Use t.uh(n) for any case test.
create or replace function t.uh(n int) returns uuid language sql immutable as $$
  select ('abcdef00-0000-0000-0000-00000000000' || n)::uuid
$$;

-- t.become(role, uid): bind auth.uid() and switch role for the rest of the transaction.
create or replace function t.become(role text, uid uuid) returns void language plpgsql as $$
begin
  perform set_config('test.uid', coalesce(uid::text, ''), true);
  execute format('set local role %I', role);
end $$;

-- t.rows(query, uid, role): how many rows `query` returns for that viewer.
-- Raises on error, so a missing table grant is loud rather than being read as "0 rows, policy worked".
create or replace function t.rows(q text, uid uuid, role text default 'authenticated') returns int
language plpgsql as $$
declare n int;
begin
  perform t.become(role, uid);
  execute format('select count(*) from (%s) as _q', q) into n;
  reset role;
  return n;
exception when others then
  reset role;
  raise;
end $$;

-- t.outcome: what a refusal looked like. `hint` carries the FC_* identifier the client maps on.
drop type if exists t.outcome cascade;
create type t.outcome as (sqlstate text, hint text, message text, rows int);

-- t.call(query, uid, role): run `query` as that viewer and report the outcome instead of raising.
-- On success: sqlstate '00000', rows = row count. On failure: the SQLSTATE, the RAISE hint and message.
-- Assert both halves -- the SQLSTATE is the wire contract, the hint is what UserFacingError maps.
-- The statement is EXECUTEd as written rather than wrapped in `select count(*) from (...)`, so that
-- INSERT/UPDATE/DELETE work too -- DML cannot appear in a subquery, and wrapping it produced a
-- syntax error (42601) that masqueraded as the refusal under test. ROW_COUNT is set for SELECT as
-- well as for DML, so one form covers both.
create or replace function t.call(q text, uid uuid, role text default 'authenticated') returns t.outcome
language plpgsql as $$
declare r t.outcome; n int;
begin
  perform t.become(role, uid);
  execute q;
  get diagnostics n = row_count;
  reset role;
  return ('00000', null, null, n)::t.outcome;
exception when others then
  reset role;
  get stacked diagnostics r.hint = pg_exception_hint, r.message = message_text;
  r.sqlstate := sqlstate;
  r.rows := null;
  return r;
end $$;

-- t.scalar(query, uid, role): the first column of the first row, as text, read as that viewer.
-- For assertions about what an RPC RETURNED rather than whether it was refused.
create or replace function t.scalar(q text, uid uuid, role text default 'authenticated') returns text
language plpgsql as $$
declare v text;
begin
  perform t.become(role, uid);
  execute q into v;
  reset role;
  return v;
exception when others then
  reset role;
  raise;
end $$;

-- t.occurrences(haystack, needle): how many times `needle` appears. Used to assert that the number
-- of `raise exception` sites in a function equals the number carrying an FC_ hint -- the drift guard
-- for the project's worst structural risk, two hand-maintained lists of error identifiers.
create or replace function t.occurrences(haystack text, needle text) returns int
language sql immutable as $$
  select ((length(haystack) - length(replace(haystack, needle, ''))) / length(needle))::int
$$;

-- t.can_select(column, table, role): does `role` hold SELECT on that one column?
-- has_column_privilege() answers for the column OR the whole table, which is exactly the question a
-- column-level REVOKE has to answer (G4).
create or replace function t.can_select(tbl text, col text, role text default 'authenticated') returns boolean
language sql stable as $$
  select has_column_privilege(role, tbl::regclass, col, 'SELECT')
$$;

grant usage on schema t to anon, authenticated, service_role;
grant execute on all functions in schema t to anon, authenticated, service_role;
