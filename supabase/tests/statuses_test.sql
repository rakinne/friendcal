-- Friend statuses (statuses.sql). Run with scripts/test-sql.sh. Helpers come from tests/helpers.sql.
-- Claims: only you and your friends read a status; only you write it; an expired or a deleted
-- person's status is never returned; no client touches the table directly.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

-- u1 Sam, u2 Maya (Sam's friend), u3 Cleo (nobody's friend), u4 Gone (deleted, Sam's friend).
insert into users(id, display_name) values (t.u(1), 'Sam'), (t.u(2), 'Maya'), (t.u(3), 'Cleo'), (t.u(4), 'Gone');
insert into friendships(user_a, user_b) values (t.u(1), t.u(2)), (t.u(1), t.u(4));
update users set deleted_at = now() where id = t.u(4);

select t.eq('signed out cannot set', (t.call($$select set_my_status('free', '', null)$$, null)).hint, 'FC_NOT_SIGNED_IN');
select t.eq('anon cannot set', (t.call($$select set_my_status('free', '', null)$$, null, 'anon')).sqlstate, '42501');
select t.eq('anon cannot read', (t.call('select * from friend_statuses()', null, 'anon')).sqlstate, '42501');
select t.eq('a deleted account cannot set', (t.call($$select set_my_status('free', '', null)$$, t.u(4))).hint, 'FC_ACCOUNT_DELETED');
select t.eq('a past end is refused', (t.call($$select set_my_status('free', '', now() - interval '1 minute')$$, t.u(2))).hint, 'FC_BAD_STATUS');
select t.eq('an unknown kind is refused', (t.call($$select set_my_status('hacking', '', null)$$, t.u(2))).sqlstate, '23514');

-- Maya sets one; messy text is flattened, trimmed and cut at 60.
select t.eq('set works', (t.call(format($$select set_my_status('movies', E'  dune\npart three  %s', now() + interval '2 hours')$$, repeat('x', 80)), t.u(2))).sqlstate, '00000');
select t.eq('newline flattened and trimmed', (select left(message, 15) from user_statuses where user_id = t.u(2)), 'dune part three');
select t.ok('message cut at 60', (select char_length(message) <= 60 from user_statuses where user_id = t.u(2)));

select t.eq('a friend sees it', t.rows($$select 1 from friend_statuses() where user_id = $$ || quote_literal(t.u(2)), t.u(1)), 1);
select t.eq('the owner sees their own', t.rows('select 1 from friend_statuses()', t.u(2)), 1);
select t.eq('a stranger sees nothing', t.rows('select 1 from friend_statuses()', t.u(3)), 0);

-- Replacing, not adding.
select t.eq('setting again replaces', (t.call($$select set_my_status('free', 'tacos', null)$$, t.u(2))).sqlstate, '00000');
select t.eq('...one row', (select count(*)::int from user_statuses where user_id = t.u(2)), 1);
select t.eq('...the new kind', (select kind from user_statuses where user_id = t.u(2)), 'free');

-- Expiry and deletion.
update user_statuses set since = now() - interval '2 hours', until = now() - interval '1 hour' where user_id = t.u(2);
select t.eq('an expired status is not returned', t.rows('select 1 from friend_statuses()', t.u(1)), 0);
insert into user_statuses(user_id, kind, since) values (t.u(4), 'free', now() - interval '1 hour');
select t.eq('a deleted friend is not returned', t.rows('select 1 from friend_statuses()', t.u(1)), 0);

-- Clearing is idempotent and only touches the caller's own row.
select t.call($$select set_my_status('gym', '', null)$$, t.u(2));
select t.eq('a stranger clearing does nothing to Maya', (t.call('select clear_my_status()', t.u(3))).sqlstate, '00000');
select t.eq('...Maya keeps it', (select count(*)::int from user_statuses where user_id = t.u(2)), 1);
select t.call('select clear_my_status()', t.u(2));
select t.call('select clear_my_status()', t.u(2));
select t.eq('clearing removes it, twice is fine', (select count(*)::int from user_statuses where user_id = t.u(2)), 0);

-- A removed friendship hides it again.
select t.call($$select set_my_status('gym', '', null)$$, t.u(2));
delete from friendships where user_a = t.u(1) and user_b = t.u(2);
select t.eq('after removal the ex-friend sees nothing', t.rows('select 1 from friend_statuses()', t.u(1)), 0);

-- No client path to the table.
select t.eq('authenticated cannot select the table', (t.call('select * from user_statuses', t.u(2))).sqlstate, '42501');
select t.eq('authenticated cannot insert into the table', (t.call(format($$insert into user_statuses(user_id, kind) values (%L, 'free')$$, t.u(3)), t.u(3))).sqlstate, '42501');
select t.ok('RLS is on', (select relrowsecurity from pg_class where oid = 'public.user_statuses'::regclass));
