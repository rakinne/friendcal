-- lock_proposal() tests. Run with scripts/test-sql.sh, which loads supabase-stubs.sql, schema.sql,
-- lock_proposal.sql, rls.sql and tests/helpers.sql into a dedicated database first.
-- Each check raises on failure, so the runner's ON_ERROR_STOP turns any failure into a nonzero exit.
-- t.ok, t.eq and t.u come from tests/helpers.sql.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

-- t.lock(...): call lock_proposal as `role` with auth.uid() = uid. Returns 'locked:<rows>' or the SQLSTATE.
create function t.lock(pid uuid, s timestamptz, e timestamptz, uid uuid, role text default 'authenticated')
returns text language plpgsql as $$
declare n int;
begin
  perform t.become(role, uid);
  select count(*) into n from lock_proposal(pid, s, e);
  reset role;
  return 'locked:' || n;
exception when others then
  reset role;
  return sqlstate;
end $$;
grant execute on all functions in schema t to anon, authenticated, service_role;

-- Fixture users u1..u7.
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
-- Scoped to this file's own fixture users: the same assertions run against an upgraded database
-- that already holds unrelated busy_blocks, so an unfiltered `from busy_blocks` would read them too.
select t.ok('busy rows are exactly the window, one per covering recipient',
  (select array_agg(user_id order by user_id) = array[t.u(1), t.u(2), t.u(3), t.u(4)]
          and bool_and(range = tstzrange(t.s(), t.e(), '[)'))
     from busy_blocks where user_id in (select t.u(n) from generate_series(1, 7) n)));
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

-- 5. G3: provenance. A Busy block promoted by a lock points back at the plan that made it, so
--    "My commitments" can name the plan instead of showing an unattributed grey block.
select t.ok('promoted Busy blocks carry the plan that created them',
  (select bool_and(source_proposal_id = '10000000-0000-0000-0000-000000000001')
     from busy_blocks
    where user_id in (select t.u(n) from generate_series(1, 4) n)
      and range = tstzrange(t.s(), t.e(), '[)')));
select t.ok('a manually added Busy block has no provenance',
  (select source_proposal_id is null from busy_blocks
    where user_id = t.u(3) and range = '[2026-11-21 18:30Z,2026-11-21 19:00Z)'));

-- 6. The RPC's return type must NOT be the busy_blocks row type. A function's return value is not
--    column-privilege checked, so `returns setof busy_blocks` would hand every caller hidden_from
--    and event_id and walk straight past the column grants in rls.sql.
select t.ok('lock_proposal returns a narrow type, not the busy_blocks row type',
  (select t.typname = 'busy_block_public'
     from pg_proc p join pg_type t on t.oid = p.prorettype
    where p.proname = 'lock_proposal'));
select t.ok('the return type exposes no correlation columns',
  not exists (select 1 from information_schema.attributes
               where udt_name = 'busy_block_public'
                 and attribute_name in ('hidden_from', 'event_id', 'source_proposal_id', 'visibility')));

-- 7. E11: every application raise carries its FC_* identifier, not just a SQLSTATE. Three distinct
--    refusals share 22023, so the hint is the only thing that tells them apart; a client that parsed
--    the message text instead would break on any wording change.
select t.seed('10000000-0000-0000-0000-000000000006');
insert into proposals(id, title, window_start, window_end, created_by, distribution)
values ('10000000-0000-0000-0000-00000000000a', 'Nobody invited',
        '2026-11-10 00:00Z', '2026-11-24 00:00Z', t.u(1), '{}'::jsonb);

create function t.lock_hint(pid text, s timestamptz, e timestamptz, uid uuid) returns text
language sql as $$
  select (t.call('select * from lock_proposal(' || quote_literal(pid) || ', '
                 || quote_literal(s) || ', ' || quote_literal(e) || ')', uid)).hint
$$;

select t.eq('FC_NOT_FOUND for a proposal that does not exist',
  t.lock_hint('10000000-0000-0000-0000-0000000000ff', t.s(), t.e(), t.u(1)), 'FC_NOT_FOUND');
select t.eq('FC_NOT_CREATOR when someone else tries to lock',
  t.lock_hint('10000000-0000-0000-0000-000000000006', t.s(), t.e(), t.u(2)), 'FC_NOT_CREATOR');
select t.eq('FC_LOCKED on a relock',
  t.lock_hint('10000000-0000-0000-0000-000000000001', t.s(), t.e(), t.u(1)), 'FC_LOCKED');
select t.eq('FC_WINDOW for a window under 60 minutes',
  t.lock_hint('10000000-0000-0000-0000-000000000006', t.s(), t.s() + interval '45 min', t.u(1)), 'FC_WINDOW');
select t.eq('FC_WINDOW for a window outside the proposal',
  t.lock_hint('10000000-0000-0000-0000-000000000006', '2026-11-30 18:00Z', '2026-11-30 19:30Z', t.u(1)), 'FC_WINDOW');
select t.eq('FC_NO_RECIPIENTS when the distribution is empty',
  t.lock_hint('10000000-0000-0000-0000-00000000000a', t.s(), t.e(), t.u(1)), 'FC_NO_RECIPIENTS');
select t.eq('FC_QUORUM when not enough people cover the window',
  t.lock_hint('10000000-0000-0000-0000-000000000006', '2026-11-14 19:30Z', '2026-11-14 20:30Z', t.u(1)), 'FC_QUORUM');

-- Every raise in the file is accounted for. FC_CHANGED is the one refusal that needs
-- two sessions, so it is asserted by the concurrency section of scripts/test-sql.sh instead; this
-- row fails if a new raise is added without a hint, which is the drift being guarded against.
select t.eq('every raise in lock_proposal carries an FC_ hint',
  (select t.occurrences(prosrc, 'raise exception') from pg_proc where proname = 'lock_proposal'),
  (select t.occurrences(prosrc, 'hint = ''FC_') from pg_proc where proname = 'lock_proposal'));

-- 8. E8: one locking protocol, in one place. A second function taking per-user locks in its own
--    order deadlocks against this one under concurrency, and only under concurrency.
select t.ok('the shared locking helper exists',
  exists (select 1 from pg_proc where proname = 'friendcal_lock_users'));
select t.ok('lock_proposal takes its per-user locks through the shared helper',
  (select prosrc like '%friendcal_lock_users%' from pg_proc where proname = 'lock_proposal'));
select t.ok('no function takes pg_advisory_xact_lock outside the shared helper',
  not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
               where n.nspname = 'public'
                 and p.proname <> 'friendcal_lock_users'
                 and p.prosrc like '%pg_advisory_xact_lock%'));

\echo 'lock_proposal tests: all passed'
