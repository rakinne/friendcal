-- RLS tests: the stealth boundary and read scoping in supabase/rls.sql.
-- Run with scripts/test-sql.sh, which loads the stubs, schema.sql, this wave's SQL and
-- tests/helpers.sql into a dedicated database first.
--
-- EVERY assertion here goes through t.rows / t.call / t.can_select, which run under
-- `set local role authenticated` (or `anon`) with auth.uid() bound. That is not a style choice:
-- this harness connects as `postgres`, which is rolsuper=t rolbypassrls=t and bypasses RLS
-- unconditionally -- `force row level security` does not change that, because FORCE constrains
-- table OWNERS, not superusers. An assertion written the obvious way, as a bare `select count(*)`,
-- passes against a deny-all policy. If you add a row here, route it through a t.* helper.
--
-- The invariant under test (docs/designs/friendcal-hub.md): an excluded viewer must still receive an
-- indistinguishable grey Busy block -- not an absent row, which is itself a tell -- while learning
-- nothing about the event behind it.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

-- Cast of viewers. u1 hosts, u2 is invited, u3 is a signed-in stranger, u4 is Jalen (excluded).
insert into users(id, display_name) select t.u(n), 'u' || n from generate_series(1, 5) n;

\set P1 30000000-0000-0000-0000-000000000001
\set P2 30000000-0000-0000-0000-000000000002
\set EV 40000000-0000-0000-0000-000000000001

-- u1's plan, with u1 and u2 invited. u3 and u4 are not party to it in any way.
insert into proposals(id, title, window_start, window_end, created_by, distribution)
values (:'P1', 'Brunch', '2026-11-10 00:00Z', '2026-11-24 00:00Z', t.u(1),
        jsonb_build_object('mode', 'newGroup', 'recipientIDs', jsonb_build_array(t.u(1), t.u(2))));
-- A second plan u1 is not party to at all, created by u5.
insert into proposals(id, title, window_start, window_end, created_by, distribution)
values (:'P2', 'Someone else''s dinner', '2026-11-10 00:00Z', '2026-11-24 00:00Z', t.u(5),
        jsonb_build_object('mode', 'newGroup', 'recipientIDs', jsonb_build_array(t.u(5))));

insert into availability_slots(user_id, range, source_proposal_id, state, expires_at) values
  (t.u(1), '[2026-11-14 18:00Z,2026-11-14 20:00Z)', :'P1', 'softHold', now() + interval '30 days'),
  (t.u(2), '[2026-11-14 18:00Z,2026-11-14 20:00Z)', :'P1', 'softHold', now() + interval '30 days'),
  (t.u(5), '[2026-11-15 18:00Z,2026-11-15 20:00Z)', :'P2', 'softHold', now() + interval '30 days');

-- The surprise: a stealth event with TWO busy_blocks whose hidden_from DISAGREE.
-- u1's row hides Jalen (u4); u2's row hides nobody. This is the hostile case -- a scalar subquery
-- over these two rows either raises "more than one row returned" or silently reads one of them, and
-- an empty hidden_from makes `= any(null)` yield NULL, which RLS reads as "not excluded".
-- Only ANY-across-rows semantics hides the event from u4.
insert into events(id, title, date, venue, host_id, attendee_ids) values
  (:'EV', 'Surprise Brunch', '2026-12-20 11:00Z', 'Rosewood', t.u(1), array[t.u(1), t.u(2)]::uuid[]);
insert into busy_blocks(user_id, range, visibility, hidden_from, event_id) values
  (t.u(1), '[2026-12-20 11:00Z,2026-12-20 13:00Z)', 'stealth', array[t.u(4)]::uuid[], :'EV'),
  (t.u(2), '[2026-12-20 11:00Z,2026-12-20 13:00Z)', 'stealth', '{}'::uuid[], :'EV');
-- An ordinary public block, nothing hidden about it.
insert into busy_blocks(user_id, range, visibility) values
  (t.u(1), '[2026-11-14 18:00Z,2026-11-14 19:30Z)', 'public');

-- ===========================================================================
-- 1. proposals: readable only by the people party to them (D6).
-- ===========================================================================
select t.eq('creator reads own plan', t.rows('select 1 from proposals where id = ' || quote_literal(:'P1'), t.u(1)), 1);
select t.eq('recipient reads the plan they were invited to', t.rows('select 1 from proposals where id = ' || quote_literal(:'P1'), t.u(2)), 1);
select t.eq('signed-in stranger reads 0 of that plan', t.rows('select 1 from proposals where id = ' || quote_literal(:'P1'), t.u(3)), 0);
select t.eq('excluded viewer reads 0 of that plan', t.rows('select 1 from proposals where id = ' || quote_literal(:'P1'), t.u(4)), 0);
-- anon is refused outright rather than filtered to zero rows: `revoke all ... from anon` means a
-- missing or mistaken policy is not the only thing between an unauthenticated caller and the table.
-- Asserting the refusal rather than "0 rows" is the stronger claim, and it is what is implemented.
select t.eq('anon is refused on proposals, not merely filtered',
  (t.call('select 1 from proposals', null, 'anon')).sqlstate, '42501');
-- The whole-table read is the one that catches a using(true) that survived scoping.
select t.eq('a stranger reads 0 proposals in total', t.rows('select 1 from proposals', t.u(3)), 0);
select t.eq('u1 reads only the plan they are party to, not u5''s', t.rows('select 1 from proposals', t.u(1)), 1);

-- ===========================================================================
-- 2. availability_slots: a hold is a private signal (D6). Holds are readable by their owner, and by
--    the creator of the plan the hold is for -- that is how the heatmap is built -- and by nobody else.
-- ===========================================================================
select t.eq('owner reads own hold', t.rows('select 1 from availability_slots where user_id = ' || quote_literal(t.u(2)), t.u(2)), 1);
select t.eq('plan creator reads the holds on their plan', t.rows('select 1 from availability_slots where source_proposal_id = ' || quote_literal(:'P1'), t.u(1)), 2);
select t.eq('stranger reads 0 holds', t.rows('select 1 from availability_slots', t.u(3)), 0);
select t.eq('excluded viewer reads 0 holds', t.rows('select 1 from availability_slots', t.u(4)), 0);
select t.eq('anon is refused on availability_slots',
  (t.call('select 1 from availability_slots', null, 'anon')).sqlstate, '42501');

-- ===========================================================================
-- 3. The stealth invariant. The excluded viewer MUST still see a busy_blocks row -- an absent row
--    is a tell -- but must not be able to read the columns that say what it is, or reach the event.
-- ===========================================================================
select t.ok('excluded viewer still receives a Busy row over the surprise window',
  t.rows('select 1 from busy_blocks where range && ''[2026-12-20 11:00Z,2026-12-20 13:00Z)''::tstzrange', t.u(4)) >= 1);
select t.ok('a stranger also receives those rows, so the excluded viewer is not distinguishable',
  t.rows('select 1 from busy_blocks where range && ''[2026-12-20 11:00Z,2026-12-20 13:00Z)''::tstzrange', t.u(3))
  = t.rows('select 1 from busy_blocks where range && ''[2026-12-20 11:00Z,2026-12-20 13:00Z)''::tstzrange', t.u(4)));

-- The column revoke (G4). These three columns are the correlation keys: hidden_from names the
-- excluded people, event_id joins two people's blocks into one event, source_proposal_id joins a
-- block back to the plan that made it. REVOKE is the enforcement -- RLS has no column granularity.
select t.ok('authenticated cannot select busy_blocks.hidden_from', not t.can_select('busy_blocks', 'hidden_from'));
select t.ok('authenticated cannot select busy_blocks.event_id', not t.can_select('busy_blocks', 'event_id'));
select t.ok('anon cannot select busy_blocks.hidden_from', not t.can_select('busy_blocks', 'hidden_from', 'anon'));
select t.ok('authenticated can still select busy_blocks.range', t.can_select('busy_blocks', 'range'));
select t.ok('authenticated can still select busy_blocks.user_id', t.can_select('busy_blocks', 'user_id'));

-- A revoked column is not merely empty, it is refused: selecting it must raise 42501, and a
-- `select *` must refuse too rather than quietly returning the column to a privileged path.
select t.eq('selecting hidden_from is refused, not blanked',
  (t.call('select hidden_from from busy_blocks', t.u(4))).sqlstate, '42501');
select t.eq('select * on busy_blocks is refused for authenticated',
  (t.call('select * from busy_blocks', t.u(4))).sqlstate, '42501');

-- ===========================================================================
-- 4. events: the excluded viewer cannot reach the event at all, and ANY excluding row is enough.
-- ===========================================================================
select t.eq('excluded viewer reads 0 events (ANY row excluding them is enough)',
  t.rows('select 1 from events where id = ' || quote_literal(:'EV'), t.u(4)), 0);
select t.eq('the host reads their own event', t.rows('select 1 from events where id = ' || quote_literal(:'EV'), t.u(1)), 1);
select t.eq('a non-excluded attendee reads the event', t.rows('select 1 from events where id = ' || quote_literal(:'EV'), t.u(2)), 1);
select t.eq('anon is refused on events',
  (t.call('select 1 from events', null, 'anon')).sqlstate, '42501');

-- The helper that answers "is this viewer excluded?" must read hidden_from, so it is security
-- definer, and the events policy cannot run unless `authenticated` may execute it. What keeps it
-- from being an oracle (outside voice F5) is its SIGNATURE: it takes an event id and NO user id, so
-- a client can only ever ask about itself. A two-argument form would let a client enumerate
-- candidate ids and read off the guest list the column revoke just hid, so assert there is none.
select t.ok('stealth_excluded() exists and is security definer',
  exists (select 1 from pg_proc where proname = 'stealth_excluded' and prosecdef));
select t.eq('stealth_excluded() takes exactly one argument, so it can only be asked about yourself',
  (select max(pronargs)::int from pg_proc where proname = 'stealth_excluded'), 1);
select t.ok('stealth_excluded() has a locked search_path',
  (select proconfig @> array['search_path=public'] from pg_proc where proname = 'stealth_excluded'));
select t.ok('stealth_excluded() is NOT executable by anon',
  not has_function_privilege('anon', 'stealth_excluded(uuid)', 'EXECUTE'));
-- And it must answer only about the caller: u3 asking about the surprise event gets false (they are
-- not in anyone's hidden_from), u4 gets true, with the SAME argument. The answer tracks auth.uid().
select t.ok('stealth_excluded() answers about the caller, not about a parameter',
  (select bool_and(v) from (values
     (t.rows('select 1 where stealth_excluded(' || quote_literal(:'EV') || ')', t.u(4)) = 1),
     (t.rows('select 1 where stealth_excluded(' || quote_literal(:'EV') || ')', t.u(3)) = 0)
   ) as _(v)));

-- ===========================================================================
-- 5. The sanitized view strips the correlation columns by construction, and inherits RLS.
-- ===========================================================================
select t.ok('sanitized_busy_blocks exposes no correlation columns',
  not exists (select 1 from information_schema.columns
               where table_schema = 'public' and table_name = 'sanitized_busy_blocks'
                 and column_name in ('hidden_from', 'event_id', 'visibility', 'source_proposal_id')));
select t.ok('the excluded viewer can read the sanitized view and still sees a row',
  t.rows('select 1 from sanitized_busy_blocks where range_start >= ''2026-12-20 00:00Z''', t.u(4)) >= 1);

-- ===========================================================================
-- 6. circles and circle_members: RLS on, and no client read path until membership ships.
-- ===========================================================================
insert into circles(id, name) values ('50000000-0000-0000-0000-000000000001', 'Roommates');
insert into circle_members(circle_id, user_id) values ('50000000-0000-0000-0000-000000000001', t.u(1));
select t.ok('circles has RLS enabled',
  (select relrowsecurity from pg_class where oid = 'circles'::regclass));
select t.ok('circle_members has RLS enabled',
  (select relrowsecurity from pg_class where oid = 'circle_members'::regclass));
-- Refused outright, not filtered to zero: the grants are gone as well as the policies, so a future
-- `create policy` on these tables cannot accidentally open a read path nobody has designed.
select t.eq('authenticated is refused on circles',
  (t.call('select 1 from circles', t.u(1))).sqlstate, '42501');
select t.eq('authenticated is refused on circle_members',
  (t.call('select 1 from circle_members', t.u(1))).sqlstate, '42501');

-- ===========================================================================
-- 7. Writes stay own-row on every table that takes client writes.
-- ===========================================================================
select t.eq('cannot insert a Busy block for someone else',
  (t.call('insert into busy_blocks(user_id, range) values (' || quote_literal(t.u(2))
          || ', ''[2027-01-01 10:00Z,2027-01-01 11:00Z)'') returning 1', t.u(1))).sqlstate, '42501');
select t.eq('cannot insert a hold for someone else',
  (t.call('insert into availability_slots(user_id, range, state) values (' || quote_literal(t.u(2))
          || ', ''[2027-01-01 10:00Z,2027-01-01 11:00Z)'', ''softHold'') returning 1', t.u(1))).sqlstate, '42501');

-- ===========================================================================
-- 8. proposals_edit_guard (F3): which fields the client may move.
--    Two independent layers, tested separately, because either alone is a single point of failure:
--    the column grants (a client cannot even name `status` in an UPDATE) and the trigger (if the
--    grants are ever widened -- Supabase re-running its own bootstrap would do it -- the trigger
--    still refuses). Layer 1 first.
-- ===========================================================================
select t.eq('the creator may rename their own plan',
  (t.call('update proposals set title = ''Renamed'' where id = ' || quote_literal(:'P1'), t.u(1))).sqlstate, '00000');
select t.eq('a client cannot name status in an UPDATE at all (column grant)',
  (t.call('update proposals set status = ''locked'' where id = ' || quote_literal(:'P1'), t.u(1))).sqlstate, '42501');
select t.eq('a client cannot name locked_date in an UPDATE (column grant)',
  (t.call('update proposals set locked_date = now() where id = ' || quote_literal(:'P1'), t.u(1))).sqlstate, '42501');
select t.eq('a client cannot name hidden_from in an UPDATE (column grant)',
  (t.call('update proposals set hidden_from = array[' || quote_literal(t.u(2)) || ']::uuid[] where id = '
          || quote_literal(:'P1'), t.u(1))).sqlstate, '42501');
select t.eq('a non-creator cannot rename the plan',
  (t.call('update proposals set title = ''Hijacked'' where id = ' || quote_literal(:'P1'), t.u(2))).rows, 0);

-- Layer 2: the trigger on its own. Widen the grant exactly as a Supabase re-bootstrap would, so the
-- UPDATE reaches the trigger, and assert the trigger refuses with the identifier the client maps on.
grant update (status) on proposals to authenticated;
select t.eq('with the grant widened, the trigger still refuses a server-owned field',
  (t.call('update proposals set status = ''locked'' where id = ' || quote_literal(:'P1'), t.u(1))).sqlstate, '42501');
select t.eq('and it refuses with FC_SERVER_OWNED_FIELD, not a bare 42501',
  (t.call('update proposals set status = ''locked'' where id = ' || quote_literal(:'P1'), t.u(1))).hint,
  'FC_SERVER_OWNED_FIELD');

-- The guard keys on definer context, not on a flag the caller can set. set_config() is executable by
-- anyone, so a marker-based guard would be forgeable from the client; prove this one is not.
select t.ok('a client cannot forge the trusted-mutation context with set_config',
  (t.call('select set_config(''friendcal.trusted_mutation'', ''on'', true); '
          || 'update proposals set status = ''locked'' where id = ' || quote_literal(:'P1'), t.u(1))).sqlstate = '42501');
revoke update (status) on proposals from authenticated;

select t.eq('the plan is still requesting after every attempt',
  (select status from proposals where id = :'P1'), 'requesting');

-- The client INSERT contract: your own plan, in the only state a new plan can be in.
select t.eq('a client may create its own requesting plan',
  (t.call('insert into proposals(id, title, window_start, window_end, created_by, distribution) values '
          || '(''30000000-0000-0000-0000-00000000000f'', ''Mine'', ''2027-01-01 00:00Z'', ''2027-01-08 00:00Z'', '
          || quote_literal(t.u(1)) || ', ''{}''::jsonb)', t.u(1))).sqlstate, '00000');
select t.eq('a client cannot create a plan that is already locked',
  (t.call('insert into proposals(id, title, window_start, window_end, created_by, distribution, status) values '
          || '(''30000000-0000-0000-0000-00000000000e'', ''Prelocked'', ''2027-01-01 00:00Z'', ''2027-01-08 00:00Z'', '
          || quote_literal(t.u(1)) || ', ''{}''::jsonb, ''locked'')', t.u(1))).sqlstate, '42501');
select t.eq('a client cannot create a plan in someone else''s name',
  (t.call('insert into proposals(id, title, window_start, window_end, created_by, distribution) values '
          || '(''30000000-0000-0000-0000-00000000000d'', ''Forged'', ''2027-01-01 00:00Z'', ''2027-01-08 00:00Z'', '
          || quote_literal(t.u(2)) || ', ''{}''::jsonb)', t.u(1))).sqlstate, '42501');
select t.eq('a client cannot create a plan whose window ends before it starts',
  (t.call('insert into proposals(id, title, window_start, window_end, created_by, distribution) values '
          || '(''30000000-0000-0000-0000-00000000000c'', ''Backwards'', ''2027-01-08 00:00Z'', ''2027-01-01 00:00Z'', '
          || quote_literal(t.u(1)) || ', ''{}''::jsonb)', t.u(1))).sqlstate, '42501');

-- ===========================================================================
-- Blanket policies from the first project setup. The live project shipped five `using (true)` policies
-- (role public) that OR every stricter policy away. This harness never creates them, so without this
-- section the drops at the top of rls.sql are dead code in CI.
--
-- Value: protects=rls.sql removes the five known blanket policies and the self-check's predicate catches a differently named one; fails_when=a drop line is removed or misnamed, or the predicate stops matching a permissive true policy; why_new=no other test seeds these policies; seam=none; no_claim=other policy names on a real project (the self-check raises for those)
-- ===========================================================================
\getenv fc_fixtures FC_FIXTURES
create policy "allow all users" on users for all using (true) with check (true);
create policy "allow all proposals" on proposals for all using (true) with check (true);
create policy "allow all busy" on busy_blocks for all using (true) with check (true);
create policy "allow all events" on events for all using (true) with check (true);
create policy "allow all availability" on availability_slots for all using (true) with check (true);
\i :fc_fixtures/../../rls.sql
select t.eq('rls.sql removed all five blanket policies',
  (select count(*)::int from pg_policies where schemaname = 'public' and policyname like 'allow all%'), 0);
select t.eq('and no other permissive true policy remains besides busy_read_all_authed',
  (select count(*)::int from pg_policies
    where schemaname = 'public' and permissive = 'PERMISSIVE' and (qual = 'true' or with_check = 'true')
      and policyname <> 'busy_read_all_authed'), 0);
create policy "Open Sesame" on proposals for all using (true) with check (true);
select t.eq('the self-check predicate sees a blanket policy under a name the drops do not know',
  (select count(*)::int from pg_policies
    where schemaname = 'public' and permissive = 'PERMISSIVE' and (qual = 'true' or with_check = 'true')
      and policyname <> 'busy_read_all_authed'), 1);
drop policy "Open Sesame" on proposals;

\echo 'rls tests: all passed'
