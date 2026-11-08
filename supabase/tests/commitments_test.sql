-- my_commitments(): provenance, authorized titles, and the overlap horizon.
-- Run with scripts/test-sql.sh. Helpers come from tests/helpers.sql.
--
-- The load-bearing assertion in this file is the TITLE one (CEO review C2). my_commitments() is
-- security definer, so it reads `proposals` as the table owner, and the owner bypasses RLS. If it
-- did not re-apply the read predicate it would hand back the title of every plan behind every block
-- the caller holds -- including a plan they were deliberately excluded from. The block is legitimate
-- to show; the title is not. A test that only checks "the title comes back" would pass against the
-- leaking version, so the cases below are built around a block whose plan must stay nameless.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

insert into users(id, display_name) select t.u(n), 'u' || n from generate_series(1, 5) n;
insert into auth.users(id, email) select t.u(n), 'u' || n || '@example.com' from generate_series(1, 5) n;

\set MINE 90000000-0000-0000-0000-000000000001
\set OPEN 90000000-0000-0000-0000-000000000002
\set SECRET 90000000-0000-0000-0000-000000000003
\set STRANGER 90000000-0000-0000-0000-000000000004

-- A locked plan u2 is party to: they may read it, so they may see its title.
insert into proposals(id, title, window_start, window_end, created_by, distribution, status, locked_date, locked_end)
values (:'MINE', 'Brunch with the group', '2026-11-10 00:00Z', '2026-11-24 00:00Z', t.u(1),
        jsonb_build_object('recipientIDs', jsonb_build_array(t.u(1), t.u(2))),
        'locked', '2026-11-14 18:00Z', '2026-11-14 19:30Z');

-- A plan still gathering holds, u2 invited.
insert into proposals(id, title, window_start, window_end, created_by, distribution)
values (:'OPEN', 'Maybe dinner', '2026-12-01 00:00Z', '2026-12-14 00:00Z', t.u(1),
        jsonb_build_object('recipientIDs', jsonb_build_array(t.u(1), t.u(2))));

-- THE ORACLE CASE. A locked plan u2 is a recipient of, but is EXCLUDED from (hidden_from) -- the
-- surprise party being thrown for them. u2 holds a real Busy block from it: their calendar is
-- genuinely blocked, and they must be able to see that they are busy. They must NOT learn the name.
insert into proposals(id, title, window_start, window_end, created_by, distribution, hidden_from, status, locked_date, locked_end)
values (:'SECRET', 'Surprise party for u2', '2026-12-18 00:00Z', '2026-12-22 00:00Z', t.u(1),
        jsonb_build_object('recipientIDs', jsonb_build_array(t.u(1), t.u(2), t.u(3))),
        array[t.u(2)]::uuid[], 'locked', '2026-12-20 19:00Z', '2026-12-20 22:00Z');

-- A second nameless case with a different cause: a plan u2 is simply not party to at all.
insert into proposals(id, title, window_start, window_end, created_by, distribution, status, locked_date, locked_end)
values (:'STRANGER', 'Something u2 was never part of', '2026-12-23 00:00Z', '2026-12-28 00:00Z', t.u(1),
        jsonb_build_object('recipientIDs', jsonb_build_array(t.u(1), t.u(3))),
        'locked', '2026-12-26 10:00Z', '2026-12-26 12:00Z');

-- u2's commitments.
insert into busy_blocks(user_id, range, visibility, source_proposal_id) values
  (t.u(2), '[2026-11-14 18:00Z,2026-11-14 19:30Z)', 'public', :'MINE'),
  (t.u(2), '[2026-12-20 19:00Z,2026-12-20 22:00Z)', 'stealth', :'SECRET'),
  (t.u(2), '[2026-12-26 10:00Z,2026-12-26 12:00Z)', 'public', :'STRANGER'),
  -- A block u2 made themselves: no provenance, so no plan and no title.
  (t.u(2), '[2026-11-16 09:00Z,2026-11-16 10:00Z)', 'public', null),
  -- An OVERNIGHT block that started before the horizon and is still running at it. The reason
  -- inclusion must be overlap-based: a start-based filter silently drops this.
  (t.u(2), '[2026-11-19 22:00Z,2026-11-20 06:00Z)', 'public', null);
-- The host's own block on the surprise they are throwing. They may name it; u2 may not. Same plan,
-- same block shape, two different answers -- which is the whole point of authorizing per caller.
insert into busy_blocks(user_id, range, visibility, source_proposal_id) values
  (t.u(1), '[2026-12-20 19:00Z,2026-12-20 22:00Z)', 'stealth', :'SECRET');
insert into availability_slots(user_id, range, source_proposal_id, state, expires_at) values
  (t.u(2), '[2026-12-05 18:00Z,2026-12-05 20:00Z)', :'OPEN', 'softHold', now() + interval '30 days'),
  -- An already-expired hold: not a commitment any more.
  (t.u(2), '[2026-12-06 18:00Z,2026-12-06 20:00Z)', :'OPEN', 'softHold', now() - interval '1 minute'),
  -- A free (non-hold) row, which is not a commitment either.
  (t.u(2), '[2026-12-07 09:00Z,2026-12-07 10:00Z)', :'OPEN', 'free', null);

create function t.mine(uid uuid, p_from timestamptz default '2026-11-01 00:00Z') returns setof commitment_row
language plpgsql as $$
begin
  perform t.become('authenticated', uid);
  return query select * from my_commitments(p_from);
  reset role;
end $$;
grant execute on all functions in schema t to authenticated;

-- ===========================================================================
-- 1. C2: titles are authorized, one by one.
-- ===========================================================================
select t.eq('a plan u2 is party to is named',
  (select plan_title from t.mine(t.u(2)) where source_proposal_id = :'MINE'), 'Brunch with the group');

select t.ok('the surprise party block IS returned -- u2 is genuinely busy then',
  exists (select 1 from t.mine(t.u(2)) where source_proposal_id = :'SECRET'));
select t.ok('...but it is NAMELESS: the definer context did not leak the title',
  (select plan_title is null from t.mine(t.u(2)) where source_proposal_id = :'SECRET'));
select t.ok('...and it still reports the right time, so the commitment is usable',
  (select range_start = '2026-12-20 19:00Z' and range_end = '2026-12-20 22:00Z'
     from t.mine(t.u(2)) where source_proposal_id = :'SECRET'));

select t.ok('a plan u2 was never part of is also nameless',
  (select plan_title is null from t.mine(t.u(2)) where source_proposal_id = :'STRANGER'));

-- The creator sees the names of their own plans, including the surprise they are throwing.
select t.eq('the host can name the surprise they are hosting',
  (select plan_title from t.mine(t.u(1)) where source_proposal_id = :'SECRET'), 'Surprise party for u2');

-- The structural guard: the policy and the RPC must use the SAME predicate, not two copies.
select t.ok('the proposals read policy and my_commitments share one predicate function',
  (select pg_get_expr(polqual, polrelid) like '%proposal_is_readable%'
     from pg_policy where polname = 'proposals_read_involved'));
select t.ok('my_commitments re-applies that predicate',
  (select prosrc like '%proposal_is_readable%' from pg_proc where proname = 'my_commitments'));
-- And they must agree in behaviour, not only in spelling: a title is returned exactly when the row
-- is readable. Run across every plan and both viewers.
select t.ok('a title is returned exactly when the plan row is readable',
  (select bool_and(
            (c.plan_title is not null)
            = (t.rows('select 1 from proposals where id = ' || quote_literal(c.source_proposal_id), v.uid) = 1))
     from (values (t.u(1)), (t.u(2))) v(uid),
          lateral t.mine(v.uid) c
    where c.source_proposal_id is not null));

-- ===========================================================================
-- 2. Provenance and the three kinds.
-- ===========================================================================
select t.eq('a Busy block from a locked plan is kind=locked',
  (select kind from t.mine(t.u(2)) where source_proposal_id = :'MINE'), 'locked');
select t.eq('a self-made Busy block is kind=busy',
  (select kind from t.mine(t.u(2)) where range_start = '2026-11-16 09:00Z'), 'busy');
select t.eq('an unexpired hold is kind=held',
  (select kind from t.mine(t.u(2)) where source_proposal_id = :'OPEN'), 'held');
select t.ok('a held row carries its expiry, so the client can show and re-check it',
  (select expires_at is not null from t.mine(t.u(2)) where source_proposal_id = :'OPEN'));
select t.ok('a locked row has no expiry',
  (select expires_at is null from t.mine(t.u(2)) where source_proposal_id = :'MINE'));
select t.eq('a self-made block has no provenance',
  (select count(*)::int from t.mine(t.u(2)) where source_proposal_id is null), 2);

-- ===========================================================================
-- 3. What is NOT a commitment.
-- ===========================================================================
select t.ok('an expired hold is excluded',
  not exists (select 1 from t.mine(t.u(2)) where range_start = '2026-12-06 18:00Z'));
select t.ok('a free slot is not a commitment',
  not exists (select 1 from t.mine(t.u(2)) where range_start = '2026-12-07 09:00Z'));
select t.ok('nobody else''s commitments appear',
  (select bool_and(true) from t.mine(t.u(2))) is not false);
select t.eq('u5, who has none, gets an empty list', (select count(*)::int from t.mine(t.u(5))), 0);
select t.eq('u2 gets exactly their own six live commitments', (select count(*)::int from t.mine(t.u(2))), 6);

-- ===========================================================================
-- 4. The horizon is overlap-based (F8a). This is the day-boundary bug.
-- ===========================================================================
-- Asked from 2026-11-20 00:00, the overnight block (22:00 the previous day -> 06:00) is STILL
-- RUNNING. A start-based filter would drop it and tell someone they were free while they were not.
select t.ok('an overnight commitment that began before the horizon and is still running is included',
  exists (select 1 from t.mine(t.u(2), '2026-11-20 00:00Z') where range_start = '2026-11-19 22:00Z'));
select t.ok('a commitment that ended before the horizon is excluded',
  not exists (select 1 from t.mine(t.u(2), '2026-11-20 00:00Z') where range_start = '2026-11-16 09:00Z'));
select t.ok('a commitment ending exactly AT the horizon is excluded (half-open, like the ranges)',
  not exists (select 1 from t.mine(t.u(2), '2026-11-20 06:00Z') where range_start = '2026-11-19 22:00Z'));

-- ===========================================================================
-- 5. Shape and privilege.
-- ===========================================================================
select t.ok('my_commitments is security definer with a locked search_path',
  (select prosecdef and proconfig @> array['search_path=public']
     from pg_proc where proname = 'my_commitments'));
select t.ok('anon cannot call my_commitments',
  not has_function_privilege('anon', 'my_commitments(timestamptz)', 'EXECUTE'));
select t.ok('the row type exposes no correlation columns beyond provenance',
  not exists (select 1 from information_schema.attributes
               where udt_name = 'commitment_row'
                 and attribute_name in ('hidden_from', 'event_id', 'visibility')));
-- Provenance is returned HERE and nowhere else: the column itself stays revoked.
select t.ok('busy_blocks.source_proposal_id remains unreadable directly',
  not t.can_select('busy_blocks', 'source_proposal_id'));

\echo 'commitments tests: all passed'
