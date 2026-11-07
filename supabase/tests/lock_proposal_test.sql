-- lock_proposal() tests. Run with scripts/test-sql.sh (loads supabase-stubs.sql and schema.sql first).
-- Each check raises on failure, so the runner's ON_ERROR_STOP turns any failure into a nonzero exit.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

create schema t;

-- t.ok(name, condition): fail loudly or print "ok - name".
create function t.ok(name text, cond boolean) returns void language plpgsql as $$
begin
  if cond is not true then raise exception 'not ok - %', name; end if;
  raise notice 'ok - %', name;
end $$;

-- t.lock(...): call lock_proposal as `role` with auth.uid() = uid. Returns 'locked:<rows>' or the SQLSTATE.
create function t.lock(pid uuid, s timestamptz, e timestamptz, uid uuid, role text default 'authenticated')
returns text language plpgsql as $$
declare n int;
begin
  perform set_config('test.uid', coalesce(uid::text, ''), true);
  execute format('set local role %I', role);
  select count(*) into n from lock_proposal(pid, s, e);
  return 'locked:' || n;
exception when others then
  return sqlstate;
end $$;
grant usage on schema t to anon, authenticated;
grant execute on all functions in schema t to anon, authenticated;

-- Fixture users u1..u7.
create function t.u(n int) returns uuid language sql immutable as $$ select ('00000000-0000-0000-0000-00000000000' || n)::uuid $$;
insert into users(id, display_name) select t.u(n), 'u' || n from generate_series(1, 7) n;

-- t.seed(pid, creator): proposal over Nov 10-24 for recipients u1..u5 (u5 listed twice), plus holds:
-- u1 17-21 covers; u2 18-19 + 19-20 touch and cover together; u3, u4 18-20 cover; u5 18:30-20 partial;
-- u6 not invited. All on Nov 14 (UTC), expiring 30 days after the test runs (expiry compares real now()).
create function t.seed(pid uuid, creator uuid default t.u(1)) returns void language sql as $$
  insert into proposals(id, title, window_start, window_end, created_by, distribution)
  values (pid, 'Brunch', '2026-11-10 00:00Z', '2026-11-24 00:00Z', creator,
          jsonb_build_object('mode', 'newGroup', 'recipientIDs',
            jsonb_build_array(t.u(1), t.u(2), t.u(3), t.u(4), t.u(5), t.u(5))));
  insert into availability_slots(user_id, range, source_proposal_id, state, expires_at) values
    (t.u(1), '[2026-11-14 17:00Z,2026-11-14 21:00Z)', pid, 'softHold', now() + interval '30 days'),
    (t.u(2), '[2026-11-14 18:00Z,2026-11-14 19:00Z)', pid, 'softHold', now() + interval '30 days'),
    (t.u(2), '[2026-11-14 19:00Z,2026-11-14 20:00Z)', pid, 'softHold', now() + interval '30 days'),
    (t.u(3), '[2026-11-14 18:00Z,2026-11-14 20:00Z)', pid, 'softHold', null),
    (t.u(4), '[2026-11-14 18:00Z,2026-11-14 20:00Z)', pid, 'softHold', now() + interval '30 days'),
    (t.u(5), '[2026-11-14 18:30Z,2026-11-14 20:00Z)', pid, 'softHold', now() + interval '30 days'),
    (t.u(6), '[2026-11-14 18:00Z,2026-11-14 20:00Z)', pid, 'softHold', now() + interval '30 days');
$$;

-- Fixed lock window used throughout.
create function t.s() returns timestamptz language sql immutable as $$ select '2026-11-14 18:00Z'::timestamptz $$;
create function t.e() returns timestamptz language sql immutable as $$ select '2026-11-14 19:30Z'::timestamptz $$;

-- 1. Happy path: 4 of 5 distinct recipients (u2 via touching holds) -> window-sized Busy for each,
--    both ends stored, this proposal's softHolds cleared, other proposals' holds and non-softHold rows kept.
select t.seed('10000000-0000-0000-0000-000000000001');
select t.seed('10000000-0000-0000-0000-000000000099', t.u(7)); -- an unrelated proposal
insert into availability_slots(user_id, range, source_proposal_id, state)
  values (t.u(1), '[2026-11-15 09:00Z,2026-11-15 10:00Z)', '10000000-0000-0000-0000-000000000001', 'free');
select t.ok('happy path locks', t.lock('10000000-0000-0000-0000-000000000001', t.s(), t.e(), t.u(1)) = 'locked:4');
select t.ok('busy rows are exactly the window, one per covering recipient',
  (select array_agg(user_id order by user_id) = array[t.u(1), t.u(2), t.u(3), t.u(4)]
          and bool_and(range = tstzrange(t.s(), t.e(), '[)'))
     from busy_blocks));
select t.ok('proposal locked with both ends',
  (select status = 'locked' and locked_date = t.s() and locked_end = t.e()
     from proposals where id = '10000000-0000-0000-0000-000000000001'));
select t.ok('this proposal''s softHolds cleared',
  not exists (select 1 from availability_slots
               where source_proposal_id = '10000000-0000-0000-0000-000000000001' and state = 'softHold'));
select t.ok('non-softHold rows of the proposal untouched',
  exists (select 1 from availability_slots
           where source_proposal_id = '10000000-0000-0000-0000-000000000001' and state = 'free'));
select t.ok('other proposal''s softHolds untouched',
  (select count(*) = 7 from availability_slots where source_proposal_id = '10000000-0000-0000-0000-000000000099'));

-- 2. Guards.
select t.ok('relock refused (55000)', t.lock('10000000-0000-0000-0000-000000000001', t.s(), t.e(), t.u(1)) = '55000');
select t.seed('10000000-0000-0000-0000-000000000002');
select t.ok('non-creator refused (42501)', t.lock('10000000-0000-0000-0000-000000000002', t.s(), t.e(), t.u(2)) = '42501');
select t.ok('anon cannot execute (42501)', t.lock('10000000-0000-0000-0000-000000000002', t.s(), t.e(), null, 'anon') = '42501');
select t.ok('window under 60 min refused', t.lock('10000000-0000-0000-0000-000000000002', t.s(), t.s() + interval '45 min', t.u(1)) = '22023');
select t.ok('null start refused', t.lock('10000000-0000-0000-0000-000000000002', null, t.e(), t.u(1)) = '22023');
select t.ok('null end refused', t.lock('10000000-0000-0000-0000-000000000002', t.s(), null, t.u(1)) = '22023');
select t.ok('window outside the proposal refused', t.lock('10000000-0000-0000-0000-000000000002', '2026-11-30 18:00Z', '2026-11-30 19:30Z', t.u(1)) = '22023');
select t.ok('below quorum refused', t.lock('10000000-0000-0000-0000-000000000002', '2026-11-14 19:30Z', '2026-11-14 20:30Z', t.u(1)) = '22023');
select t.ok('a refused lock changes nothing',
  (select status = 'requesting' from proposals where id = '10000000-0000-0000-0000-000000000002')
  and (select count(*) = 7 from availability_slots where source_proposal_id = '10000000-0000-0000-0000-000000000002'));
select t.ok('caller cannot pick the quorum', not exists (
  select 1 from pg_proc where proname = 'lock_proposal' and pronargs <> 3));
select t.seed('10000000-0000-0000-0000-000000000003', null);
select t.ok('proposal without a creator refused', t.lock('10000000-0000-0000-0000-000000000003', t.s(), t.e(), t.u(1)) = '42501');

-- 3. Expired holds do not count: expire u4 on proposal 2 -> 3 of 5 = 60%.
update availability_slots set expires_at = now() - interval '1 minute'
 where source_proposal_id = '10000000-0000-0000-0000-000000000002' and user_id = t.u(4);
select t.ok('expired hold not counted', t.lock('10000000-0000-0000-0000-000000000002', t.s(), t.e(), t.u(1)) = '22023');

-- 4. A recipient already Busy over the window is not free: they neither count nor block the lock.
--    Proposal 4: all five recipients cover; u3 already has a manual Busy block -> 4 of 5 still locks.
select t.seed('10000000-0000-0000-0000-000000000004');
delete from availability_slots where source_proposal_id = '10000000-0000-0000-0000-000000000004';
insert into availability_slots(user_id, range, source_proposal_id, state, expires_at)
  select t.u(n), '[2026-11-21 18:00Z,2026-11-21 20:00Z)', '10000000-0000-0000-0000-000000000004', 'softHold', now() + interval '30 days'
    from generate_series(1, 5) n;
insert into busy_blocks(user_id, range) values (t.u(3), '[2026-11-21 18:30Z,2026-11-21 19:00Z)');
select t.ok('busy recipient skipped, lock still succeeds',
  t.lock('10000000-0000-0000-0000-000000000004', '2026-11-21 18:00Z', '2026-11-21 19:30Z', t.u(1)) = 'locked:4');
select t.ok('busy recipient got no second block',
  (select count(*) = 1 from busy_blocks where user_id = t.u(3) and range && '[2026-11-21 18:00Z,2026-11-21 19:30Z)'));
--    Proposal 5: only u1..u4 cover and u3 is busy -> 3 of 5 = 60%: refused as quorum, not a constraint error.
select t.seed('10000000-0000-0000-0000-000000000005');
delete from availability_slots where source_proposal_id = '10000000-0000-0000-0000-000000000005';
insert into availability_slots(user_id, range, source_proposal_id, state, expires_at)
  select t.u(n), '[2026-11-21 18:00Z,2026-11-21 20:00Z)', '10000000-0000-0000-0000-000000000005', 'softHold', now() + interval '30 days'
    from generate_series(1, 4) n;
select t.ok('busy recipient below quorum is a quorum refusal, not 23P01',
  t.lock('10000000-0000-0000-0000-000000000005', '2026-11-21 18:00Z', '2026-11-21 19:30Z', t.u(1)) = '22023');

\echo 'lock_proposal tests: all passed'
