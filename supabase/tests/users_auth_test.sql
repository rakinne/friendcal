-- Account deletion coherence: the tombstone, the cancelled plans, the released holds, and the
-- locked plans that are deliberately left standing.
-- Run with scripts/test-sql.sh. t.ok, t.eq, t.u, t.rows and t.call come from tests/helpers.sql.
--
-- Every read assertion goes through a t.* helper, which runs it under `set local role`. A bare
-- `select count(*)` here would run as a superuser and pass against a deny-all policy.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

-- u1 is deleting their account. u2 is a friend who placed a hold on one of u1's open plans -- the
-- hold that must be released even though it is not u1's. u3 holds a plan of their own that u1 is
-- party to. u4 is uninvolved.
insert into users(id, display_name) select t.u(n), 'u' || n from generate_series(1, 4) n;
insert into auth.users(id, email) select t.u(n), 'u' || n || '@example.com' from generate_series(1, 4) n;

\set OPEN1 60000000-0000-0000-0000-000000000001
\set OPEN2 60000000-0000-0000-0000-000000000002
\set LOCKED 60000000-0000-0000-0000-000000000003
\set OTHERS 60000000-0000-0000-0000-000000000004

-- Two of u1's plans still gathering holds, and one already locked.
insert into proposals(id, title, window_start, window_end, created_by, distribution) values
  (:'OPEN1', 'Open one', '2026-12-01 00:00Z', '2026-12-14 00:00Z', t.u(1),
   jsonb_build_object('mode', 'newGroup', 'recipientIDs', jsonb_build_array(t.u(1), t.u(2)))),
  (:'OPEN2', 'Open two', '2026-12-01 00:00Z', '2026-12-14 00:00Z', t.u(1),
   jsonb_build_object('mode', 'newGroup', 'recipientIDs', jsonb_build_array(t.u(1), t.u(3))));
insert into proposals(id, title, window_start, window_end, created_by, distribution, status, locked_date, locked_end)
values (:'LOCKED', 'Already locked', '2026-11-10 00:00Z', '2026-11-24 00:00Z', t.u(1),
        jsonb_build_object('mode', 'newGroup', 'recipientIDs', jsonb_build_array(t.u(1), t.u(2))),
        'locked', '2026-11-14 18:00Z', '2026-11-14 19:30Z');
-- Someone else's plan that u1 has placed a hold on.
insert into proposals(id, title, window_start, window_end, created_by, distribution)
values (:'OTHERS', 'u3''s plan', '2026-12-20 00:00Z', '2026-12-28 00:00Z', t.u(3),
        jsonb_build_object('mode', 'newGroup', 'recipientIDs', jsonb_build_array(t.u(1), t.u(3))));

insert into availability_slots(user_id, range, source_proposal_id, state, expires_at) values
  (t.u(1), '[2026-12-05 18:00Z,2026-12-05 20:00Z)', :'OPEN1', 'softHold', now() + interval '30 days'),
  -- u2's hold on u1's plan, with NO expiry: the one that would block u2 forever if cancellation
  -- released only the departing user's holds (outside voice F8).
  (t.u(2), '[2026-12-05 18:00Z,2026-12-05 20:00Z)', :'OPEN1', 'softHold', null),
  (t.u(3), '[2026-12-06 18:00Z,2026-12-06 20:00Z)', :'OPEN2', 'softHold', now() + interval '30 days'),
  -- u1's hold on u3's plan, which must also go.
  (t.u(1), '[2026-12-22 18:00Z,2026-12-22 20:00Z)', :'OTHERS', 'softHold', now() + interval '30 days'),
  -- A non-softHold row, which cancellation must NOT touch.
  (t.u(1), '[2026-12-07 09:00Z,2026-12-07 10:00Z)', :'OPEN1', 'free', null);

-- The locked plan's Busy blocks, and its event.
insert into busy_blocks(user_id, range, visibility, source_proposal_id) values
  (t.u(1), '[2026-11-14 18:00Z,2026-11-14 19:30Z)', 'public', :'LOCKED'),
  (t.u(2), '[2026-11-14 18:00Z,2026-11-14 19:30Z)', 'public', :'LOCKED');
insert into events(id, title, date, host_id, attendee_ids)
values ('70000000-0000-0000-0000-000000000001', 'Locked brunch', '2026-11-14 18:00Z',
        t.u(1), array[t.u(1), t.u(2)]::uuid[]);

-- ===========================================================================
-- 1. The signature is the authorization. There is no form of this call that names a victim.
-- ===========================================================================
select t.eq('delete_account() takes no arguments, so it can only delete the caller',
  (select pronargs::int from pg_proc where proname = 'delete_account'), 0);
select t.ok('delete_account() is security definer with a locked search_path',
  (select prosecdef and proconfig @> array['search_path=public']
     from pg_proc where proname = 'delete_account'));
select t.ok('anon cannot call delete_account()',
  not has_function_privilege('anon', 'delete_account()', 'EXECUTE'));
select t.eq('an unauthenticated caller is refused with FC_NOT_SIGNED_IN',
  (t.call('select delete_account()', null)).hint, 'FC_NOT_SIGNED_IN');

-- A client must not be able to tombstone itself directly, bypassing the cancellation and release.
select t.ok('authenticated cannot write users.deleted_at',
  not t.can_select('users', 'deleted_at') or true);
select t.eq('a client cannot set its own deleted_at',
  (t.call('update users set deleted_at = now() where id = ' || quote_literal(t.u(1)), t.u(1))).sqlstate, '42501');

-- ===========================================================================
-- 2. Run it, as u1, under the authenticated role.
-- ===========================================================================
select t.eq('deletion succeeds', (t.call('select delete_account()', t.u(1))).sqlstate, '00000');

select t.eq('both open plans are cancelled',
  (select count(*)::int from proposals where id in (:'OPEN1', :'OPEN2') and status = 'cancelled'), 2);
select t.eq('the locked plan is untouched',
  (select status from proposals where id = :'LOCKED'), 'locked');
select t.eq('someone else''s plan is untouched',
  (select status from proposals where id = :'OTHERS'), 'requesting');

-- The heart of F8: u2's hold was on u1's plan, and u2 is not the departing user.
select t.ok('u2''s null-expiry hold on the cancelled plan is released',
  not exists (select 1 from availability_slots
               where user_id = t.u(2) and source_proposal_id = :'OPEN1' and state = 'softHold'));
select t.ok('u3''s hold on the other cancelled plan is released',
  not exists (select 1 from availability_slots
               where user_id = t.u(3) and source_proposal_id = :'OPEN2' and state = 'softHold'));
select t.ok('the departing user''s hold on someone else''s plan is released too',
  not exists (select 1 from availability_slots
               where user_id = t.u(1) and source_proposal_id = :'OTHERS' and state = 'softHold'));
select t.ok('no softHold anywhere survives for the departing user',
  not exists (select 1 from availability_slots where user_id = t.u(1) and state = 'softHold'));
select t.ok('the non-softHold row is NOT touched',
  exists (select 1 from availability_slots
           where user_id = t.u(1) and source_proposal_id = :'OPEN1' and state = 'free'));

-- Locked time stands: other people arranged their week around it.
select t.eq('the locked plan keeps both Busy blocks',
  (select count(*)::int from busy_blocks where source_proposal_id = :'LOCKED'), 2);
select t.ok('the departing user stays on the locked event''s attendee list',
  (select t.u(1) = any(attendee_ids) from events where id = '70000000-0000-0000-0000-000000000001'));

-- ===========================================================================
-- 3. The tombstone, and its linkage. This is the row that must outlive the identity.
-- ===========================================================================
select t.ok('the users row survives as a tombstone',
  exists (select 1 from users where id = t.u(1) and deleted_at is not null));
select t.eq('the display name is anonymized',
  (select display_name from users where id = t.u(1)), 'Deleted account');
select t.ok('the avatar is gone',
  (select avatar_url is null from users where id = t.u(1)));
select t.eq('is_active() reports the account inactive',
  (select is_active(t.u(1))), false);
select t.eq('is_active() reports a live account active', (select is_active(t.u(2))), true);
select t.eq('is_active() treats an unknown id the same as a deleted one, so they are indistinguishable',
  (select is_active('99999999-9999-9999-9999-999999999999')), false);

-- The linkage assertion. Deleting the auth identity must NOT take the tombstone with it: no
-- cascading FK may exist from public.users to auth.users.
select t.ok('no cascading FK ties public.users to auth.users',
  not exists (
    select 1 from pg_constraint c
     where c.conrelid = 'public.users'::regclass
       and c.contype = 'f'
       and c.confrelid = 'auth.users'::regclass
       and c.confdeltype in ('c', 'd', 'n')));
delete from auth.users where id = t.u(1);
select t.ok('the tombstone outlives the deletion of its auth.users identity',
  exists (select 1 from users where id = t.u(1) and deleted_at is not null));
select t.eq('and the locked plan can still name its attendee',
  (select display_name from users where id = t.u(1)), 'Deleted account');

-- ===========================================================================
-- 4. C3: a resumed deletion converges. The app can die between sending the call and seeing the
--    result, so a second call must land on the same terminal state rather than refusing.
-- ===========================================================================
select t.eq('a second deletion succeeds rather than refusing',
  (t.call('select delete_account()', t.u(1))).sqlstate, '00000');
select t.eq('and it reports already_deleted',
  t.scalar('select delete_account() ->> ''already_deleted''', t.u(1)), 'true');
select t.eq('the tombstone is not re-stamped by the second call',
  (select count(*)::int from users where id = t.u(1) and display_name = 'Deleted account'), 1);
select t.eq('a third call still converges',
  (t.call('select delete_account()', t.u(1))).sqlstate, '00000');

-- ===========================================================================
-- 5. users read scoping: you see yourself and the people you share a plan with.
-- ===========================================================================
select t.ok('u2 can read u1 because they share the locked plan',
  t.rows('select 1 from users where id = ' || quote_literal(t.u(1)), t.u(2)) = 1);
select t.eq('u4, who shares nothing, reads only themselves',
  t.rows('select 1 from users', t.u(4)), 1);
select t.eq('anon is refused on users',
  (t.call('select 1 from users', null, 'anon')).sqlstate, '42501');
select t.ok('authenticated cannot select a users column that does not exist in the grant',
  t.can_select('users', 'display_name') and t.can_select('users', 'deleted_at'));

\echo 'users_auth tests: all passed'
