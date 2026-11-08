-- CP5: the whole recipient loop, two users, end to end, through the real client paths.
-- Run with scripts/test-sql.sh. Helpers come from tests/helpers.sql.
--
-- Every other test file in this directory proves one piece in isolation. This one proves they
-- COMPOSE, which is a different claim and the one that actually ships: a plan created by a client
-- INSERT, shared as a link, joined by someone who cannot yet read it, held by both people, locked by
-- the creator, and showing up in both people's commitments with the right name. Each step runs as
-- the role that step really runs as, so a missing grant or a policy that only works for the creator
-- fails here even when every unit test passes.
--
-- A third viewer follows the same plan the whole way through and must learn nothing at any step.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

insert into users(id, display_name) select t.u(n), 'u' || n from generate_series(1, 3) n;
insert into auth.users(id, email) select t.u(n), 'u' || n || '@example.com' from generate_series(1, 3) n;

\set PLAN a0000000-0000-0000-0000-000000000001
\set WSTART '2026-12-01 00:00Z'
\set WEND '2026-12-14 00:00Z'
\set LSTART '2026-12-05 18:00Z'
\set LEND '2026-12-05 19:30Z'

-- ===========================================================================
-- Step 1. u1 creates the plan the way the client does: a plain INSERT as `authenticated`,
--         constrained by proposals_insert_own. Not as a superuser, and not through an RPC.
-- ===========================================================================
select t.eq('u1 creates a plan',
  (t.call('insert into proposals(id, title, window_start, window_end, created_by, distribution) values ('
          || quote_literal(:'PLAN') || ', ''Dinner somewhere'', ' || quote_literal(:'WSTART') || ', '
          || quote_literal(:'WEND') || ', ' || quote_literal(t.u(1)) || ', '
          || quote_literal('{"mode":"newGroup","expectedCount":2,"recipientIDs":["' || t.u(1) || '"]}') || '::jsonb)',
          t.u(1))).sqlstate, '00000');
select t.eq('the plan starts out requesting', (select status from proposals where id = :'PLAN'), 'requesting');
select t.ok('with no exclusions, because a client cannot set hidden_from',
  (select hidden_from = '{}'::uuid[] from proposals where id = :'PLAN'));
select t.ok('and authenticated holds no INSERT privilege on hidden_from at all',
  not has_column_privilege('authenticated', 'proposals', 'hidden_from', 'INSERT'));

select t.eq('u1 can read their own plan', t.rows('select 1 from proposals where id = ' || quote_literal(:'PLAN'), t.u(1)), 1);
select t.eq('u2, who holds nothing yet, cannot', t.rows('select 1 from proposals where id = ' || quote_literal(:'PLAN'), t.u(2)), 0);
select t.eq('u3 cannot either', t.rows('select 1 from proposals where id = ' || quote_literal(:'PLAN'), t.u(3)), 0);

-- ===========================================================================
-- Step 2. u1 shares the link. u2 taps it and joins BEFORE being able to load the plan -- the
--         ordering the whole loop hangs on (outside voice F7).
-- ===========================================================================
select t.eq('u2 joins from the link without ever having read the plan',
  t.scalar('select join_proposal(' || quote_literal(:'PLAN') || ') ->> ''title''', t.u(2)), 'Dinner somewhere');
select t.eq('now u2 can read it', t.rows('select 1 from proposals where id = ' || quote_literal(:'PLAN'), t.u(2)), 1);
select t.eq('u3 still cannot', t.rows('select 1 from proposals where id = ' || quote_literal(:'PLAN'), t.u(3)), 0);
select t.eq('the plan now lists two recipients',
  t.scalar('select recipient_count::text from proposal_summaries where id = ' || quote_literal(:'PLAN'), t.u(1)), '2');

-- ===========================================================================
-- Step 3. Both people hold the same window, as clients, on their own rows only.
-- ===========================================================================
select t.eq('u1 holds the window',
  (t.call('insert into availability_slots(user_id, range, source_proposal_id, state, expires_at) values ('
          || quote_literal(t.u(1)) || ', ''[2026-12-05 17:00Z,2026-12-05 21:00Z)'', '
          || quote_literal(:'PLAN') || ', ''softHold'', now() + interval ''7 days'')', t.u(1))).sqlstate, '00000');
select t.eq('u2 holds it too',
  (t.call('insert into availability_slots(user_id, range, source_proposal_id, state, expires_at) values ('
          || quote_literal(t.u(2)) || ', ''[2026-12-05 18:00Z,2026-12-05 20:00Z)'', '
          || quote_literal(:'PLAN') || ', ''softHold'', now() + interval ''7 days'')', t.u(2))).sqlstate, '00000');
select t.eq('u3 cannot plant a hold on a plan they are not party to',
  (t.call('insert into availability_slots(user_id, range, source_proposal_id, state, expires_at) values ('
          || quote_literal(t.u(3)) || ', ''[2026-12-05 18:00Z,2026-12-05 20:00Z)'', '
          || quote_literal(:'PLAN') || ', ''softHold'', now() + interval ''7 days'')', t.u(3))).sqlstate, '00000');
-- That insert SUCCEEDS -- the write policy only checks that the row is u3's own. What u3 cannot do
-- is see anyone else's holds, or affect the lock, which the next assertions pin down. Worth stating
-- plainly: holds are not membership-checked on write, only on read.
select t.eq('u1 sees both real holds on their plan, for the heatmap',
  t.rows('select 1 from availability_slots where source_proposal_id = ' || quote_literal(:'PLAN')
         || ' and user_id in (' || quote_literal(t.u(1)) || ', ' || quote_literal(t.u(2)) || ')', t.u(1)), 2);
select t.eq('u2 sees only their own hold',
  t.rows('select 1 from availability_slots where source_proposal_id = ' || quote_literal(:'PLAN'), t.u(2)), 1);
select t.eq('u3 sees only their own',
  t.rows('select 1 from availability_slots where source_proposal_id = ' || quote_literal(:'PLAN'), t.u(3)), 1);

-- ===========================================================================
-- Step 4. u1 locks it. Only the creator may, and the server re-derives who is free.
-- ===========================================================================
select t.eq('u2 cannot lock someone else''s plan',
  (t.call('select * from lock_proposal(' || quote_literal(:'PLAN') || ', ' || quote_literal(:'LSTART')
          || ', ' || quote_literal(:'LEND') || ')', t.u(2))).hint, 'FC_NOT_CREATOR');
select t.eq('u1 locks it, promoting one Busy block per covering recipient',
  (t.call('select * from lock_proposal(' || quote_literal(:'PLAN') || ', ' || quote_literal(:'LSTART')
          || ', ' || quote_literal(:'LEND') || ')', t.u(1))).rows, 2);
-- Compared as timestamptz values, never as rendered text: ::text formats in the session's zone, so
-- a text comparison here passes in UTC and fails in any other timezone.
select t.ok('the plan is locked with both ends',
  (select status = 'locked'
          and locked_date = :'LSTART'::timestamptz
          and locked_end = :'LEND'::timestamptz
     from proposals where id = :'PLAN'));
select t.ok('every softHold on the plan is cleared, including u3''s stray one',
  not exists (select 1 from availability_slots where source_proposal_id = :'PLAN' and state = 'softHold'));
select t.eq('u3 got no Busy block, having never been a recipient',
  (select count(*)::int from busy_blocks where user_id = t.u(3)), 0);
select t.eq('the two Busy blocks carry the plan that made them',
  (select count(*)::int from busy_blocks where source_proposal_id = :'PLAN'), 2);

-- ===========================================================================
-- Step 5. Both people's commitments now name the plan. This is the screen the wave is building.
-- ===========================================================================
create function t.mine(uid uuid) returns setof commitment_row language plpgsql as $$
begin
  perform t.become('authenticated', uid);
  return query select * from my_commitments('2026-12-01 00:00Z');
  reset role;
end $$;
grant execute on all functions in schema t to authenticated;

select t.eq('u1 has exactly one commitment', (select count(*)::int from t.mine(t.u(1))), 1);
select t.eq('...and it is the locked dinner, by name',
  (select kind || ': ' || plan_title from t.mine(t.u(1))), 'locked: Dinner somewhere');
select t.eq('u2 has exactly one commitment', (select count(*)::int from t.mine(t.u(2))), 1);
select t.eq('...named the same way, for the other participant',
  (select kind || ': ' || plan_title from t.mine(t.u(2))), 'locked: Dinner somewhere');
select t.ok('both commitments are the locked window itself',
  (select bool_and(range_start = '2026-12-05 18:00Z' and range_end = '2026-12-05 19:30Z')
     from (select * from t.mine(t.u(1)) union all select * from t.mine(t.u(2))) _));
select t.eq('u3 has no commitments', (select count(*)::int from t.mine(t.u(3))), 0);

-- Provenance reached the client through the RPC and ONLY through the RPC.
select t.ok('neither participant can read source_proposal_id off the table directly',
  not t.can_select('busy_blocks', 'source_proposal_id'));
select t.eq('and a direct select of it is refused',
  (t.call('select source_proposal_id from busy_blocks', t.u(2))).sqlstate, '42501');

-- ===========================================================================
-- Step 6. The stealth half of the loop. u3 is now excluded from a second, locked plan that they
--         nonetheless hold a Busy block for -- the surprise-party shape. Set as the table owner
--         because no client path sets hidden_from in this wave; the RPC that will is next wave's.
-- ===========================================================================
\set SURPRISE a0000000-0000-0000-0000-000000000002
insert into proposals(id, title, window_start, window_end, created_by, distribution, hidden_from, status, locked_date, locked_end)
values (:'SURPRISE', 'Surprise for u3', '2026-12-18 00:00Z', '2026-12-22 00:00Z', t.u(1),
        jsonb_build_object('recipientIDs', jsonb_build_array(t.u(1), t.u(2), t.u(3))),
        array[t.u(3)]::uuid[], 'locked', '2026-12-20 19:00Z', '2026-12-20 22:00Z');
insert into events(id, title, date, host_id, attendee_ids, busy_block_ids)
values ('b0000000-0000-0000-0000-000000000001', 'Surprise for u3', '2026-12-20 19:00Z',
        t.u(1), array[t.u(1), t.u(2)]::uuid[], '{}');
-- All three people are blocked for the surprise: u1 and u2 are throwing it, u3 is the subject and
-- is excluded. Three blocks, one event. u3 must see all three rows -- seeing FEWER rows than the
-- others is as much a tell as seeing the title would be.
insert into busy_blocks(user_id, range, visibility, hidden_from, event_id, source_proposal_id) values
  (t.u(1), '[2026-12-20 19:00Z,2026-12-20 22:00Z)', 'stealth', array[t.u(3)]::uuid[],
   'b0000000-0000-0000-0000-000000000001', :'SURPRISE'),
  (t.u(2), '[2026-12-20 19:00Z,2026-12-20 22:00Z)', 'stealth', array[t.u(3)]::uuid[],
   'b0000000-0000-0000-0000-000000000001', :'SURPRISE'),
  (t.u(3), '[2026-12-20 19:00Z,2026-12-20 22:00Z)', 'stealth', array[t.u(3)]::uuid[],
   'b0000000-0000-0000-0000-000000000001', :'SURPRISE');

select t.eq('u3 cannot read the plan they are excluded from',
  t.rows('select 1 from proposals where id = ' || quote_literal(:'SURPRISE'), t.u(3)), 0);
select t.eq('u3 cannot reach the event', t.rows('select 1 from events', t.u(3)), 0);
select t.eq('u3''s forwarded link tells them nothing',
  (t.call('select join_proposal(' || quote_literal(:'SURPRISE') || ')', t.u(3))).hint, 'FC_NOT_FOUND');
select t.eq('u3 sees ALL THREE Busy rows over that window -- a short count is itself a tell',
  t.rows('select 1 from busy_blocks where range && ''[2026-12-20 19:00Z,2026-12-20 22:00Z)''::tstzrange', t.u(3)), 3);
select t.ok('and u3 sees exactly what the people in on it see',
  t.rows('select 1 from busy_blocks where range && ''[2026-12-20 19:00Z,2026-12-20 22:00Z)''::tstzrange', t.u(3))
  = t.rows('select 1 from busy_blocks where range && ''[2026-12-20 19:00Z,2026-12-20 22:00Z)''::tstzrange', t.u(1)));
select t.ok('u3''s own commitment for it appears, so their calendar is honest',
  exists (select 1 from t.mine(t.u(3)) where range_start = '2026-12-20 19:00Z'));
select t.ok('...but it is nameless',
  (select plan_title is null from t.mine(t.u(3)) where range_start = '2026-12-20 19:00Z'));
select t.eq('while u2, who is in on it, sees the name',
  (select plan_title from t.mine(t.u(2)) where range_start = '2026-12-20 19:00Z'), 'Surprise for u3');
select t.eq('u3 cannot read hidden_from to find out who was left out',
  (t.call('select hidden_from from busy_blocks', t.u(3))).sqlstate, '42501');
select t.eq('nor event_id, which would join the two blocks into one event',
  (t.call('select event_id from busy_blocks', t.u(3))).sqlstate, '42501');

\echo 'loop tests: all passed'
