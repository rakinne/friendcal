-- Add a friend (friends.sql, plus the pieces in schema_additions.sql, users_auth.sql and social.sql).
-- Run with scripts/test-sql.sh. Helpers come from tests/helpers.sql.
--
-- Three claims carry this file. A link either connects two people once or says `dead` -- and says
-- the same `dead` for every cause, from preview and accept alike. A friendship grants a name and a
-- poke and NOTHING else: no plan, place, vote or Busy-block detail becomes readable. And no client
-- can touch the friend tables or call a friend function as anon. The races (accept against reset,
-- deletion and removal; poke against removal) are in the concurrency section of test-sql.sh.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

-- u1 Sam (link owner). u2 Maya, u3 Leo, u4 Jalen, u5 Arlo: people who open links. u6 deleted.
-- u7 Cleo: Sam's plan recipient and nobody's friend. u8 Mika: removes and reconnects.
insert into users(id, display_name) values
  (t.u(1), 'Sam'), (t.u(2), 'Maya'), (t.u(3), 'Leo'), (t.u(4), 'Jalen'),
  (t.u(5), 'Arlo'), (t.u(6), 'Gone'), (t.u(7), 'Cleo'), (t.u(8), 'Mika');
update users set deleted_at = now(), display_name = 'Deleted account' where id = t.u(6);

create or replace function t.link(p_uid uuid) returns text language sql as $$
  select t.scalar('select friend_link() ->> ''token''', p_uid)
$$;
create or replace function t.status(p_fn text, p_uid uuid, p_token text) returns text language sql as $$
  select t.scalar(format('select %s(%L) ->> ''status''', p_fn, p_token), p_uid)
$$;
create or replace function t.preview(p_uid uuid, p_token text) returns text language sql as $$ select t.status('preview_friend_link', p_uid, p_token) $$;
create or replace function t.accept(p_uid uuid, p_token text) returns text language sql as $$ select t.status('accept_friend_link', p_uid, p_token) $$;
create or replace function t.pair(p_a uuid, p_b uuid) returns int language sql as $$
  select count(*)::int from friendships where user_a = least(p_a, p_b) and user_b = greatest(p_a, p_b)
$$;
-- Does the self-check fail after `setup` (which is rolled back)? Variables survive a rolled-back
-- subtransaction, so `failed` carries the answer out.
create or replace function t.check_fails(setup text) returns boolean language plpgsql as $$
declare failed boolean := false;
begin
  begin
    execute setup;
    begin perform friendcal_friends_selfcheck(); exception when others then failed := true; end;
    raise exception 'roll back the setup';
  exception when others then null;
  end;
  return failed;
end $$;

-- ===========================================================================
-- 1. The link: minted once, 22 characters, nobody else's.
-- ===========================================================================
select t.eq('signed out cannot mint', (t.call('select friend_link()', null)).hint, 'FC_NOT_SIGNED_IN');
select t.eq('a deleted account cannot mint', (t.call('select friend_link()', t.u(6))).hint, 'FC_ACCOUNT_DELETED');
select t.eq('an id with no users row cannot mint',
  (t.call('select friend_link()', '00000000-0000-0000-0000-0000000000ee'::uuid)).hint, 'FC_ACCOUNT_DELETED');
select t.eq('anon cannot call friend_link', (t.call('select friend_link()', null, 'anon')).sqlstate, '42501');

select t.link(t.u(1)) as sam_token \gset
select t.ok('the token is 22 characters of base64url', :'sam_token' ~ '^[A-Za-z0-9_-]{22}$');
select t.eq('opening the sheet again returns the same link', t.link(t.u(1)), :'sam_token');
select t.eq('...from one row', (select count(*)::int from friend_links where user_id = t.u(1)), 1);
select t.eq('...minted once', (select mint_count from friend_links where user_id = t.u(1)), 1);
select t.ok('another person gets another token', t.link(t.u(2)) <> :'sam_token');
select t.eq('1,000 mints: every token is distinct, 22 characters and in the alphabet',
  (select count(distinct tok)::int from (select friendcal_new_friend_token() as tok from generate_series(1, 1000)) x
    where tok ~ '^[A-Za-z0-9_-]{22}$'), 1000);

-- ===========================================================================
-- 2. Preview: four answers, and it changes nothing.
-- ===========================================================================
select t.eq('a stranger previews a valid link', t.preview(t.u(3), :'sam_token'), 'valid');
select t.eq('...and is told who it is, from the server',
  t.scalar(format('select preview_friend_link(%L) ->> ''display_name''', :'sam_token'), t.u(3)), 'Sam');
select t.eq('...with the inviter''s id',
  t.scalar(format('select preview_friend_link(%L) ->> ''user_id''', :'sam_token'), t.u(3)), t.u(1)::text);
select t.eq('the owner previews their own link as own', t.preview(t.u(1), :'sam_token'), 'own');
select t.ok('...and own names no one',
  t.scalar(format('select (preview_friend_link(%L) ? ''display_name'')::text', :'sam_token'), t.u(1)) = 'false');
select t.eq('an unknown token is dead', t.preview(t.u(3), repeat('A', 22)), 'dead');
select t.eq('a token of 21 characters is dead', t.preview(t.u(3), repeat('A', 21)), 'dead');
select t.eq('a token of 23 characters is dead', t.preview(t.u(3), repeat('A', 23)), 'dead');
select t.eq('a token with a character outside the alphabet is dead', t.preview(t.u(3), repeat('A', 21) || '+'), 'dead');
select t.eq('a null token is dead',
  t.scalar('select preview_friend_link(null) ->> ''status''', t.u(3)), 'dead');
select t.ok('a dead answer carries nothing but the status',
  t.scalar(format('select preview_friend_link(%L)::text', repeat('A', 22)), t.u(3)) = '{"status": "dead"}');
select t.eq('previewing connected nobody', (select count(*)::int from friendships), 0);
select t.eq('...counted nothing', (select token_accepts + accept_count from friend_links where user_id = t.u(1)), 0);
select t.eq('...and queued nothing', (select count(*)::int from push_outbox), 0);
select t.eq('signed out cannot preview', (t.call(format('select preview_friend_link(%L)', :'sam_token'), null)).hint, 'FC_NOT_SIGNED_IN');
select t.eq('a deleted account cannot preview',
  (t.call(format('select preview_friend_link(%L)', :'sam_token'), t.u(6))).hint, 'FC_ACCOUNT_DELETED');
select t.eq('anon cannot preview', (t.call(format('select preview_friend_link(%L)', :'sam_token'), null, 'anon')).sqlstate, '42501');

-- ===========================================================================
-- 3. Accept: one friendship, one push, idempotent.
-- ===========================================================================
select t.eq('own link: nothing to connect', t.accept(t.u(1), :'sam_token'), 'own');
select t.eq('...and nothing was written', (select count(*)::int from friendships), 0);

select t.eq('Maya accepts Sam''s link', t.accept(t.u(2), :'sam_token'), 'valid');
select t.eq('...one friendship', t.pair(t.u(1), t.u(2)), 1);
select t.ok('...stored smaller id first', (select user_a < user_b from friendships limit 1));
select t.eq('...the link counted it',
  (select token_accepts || '/' || accept_count || '/' || (last_accepted_at is not null) from friend_links where user_id = t.u(1)), '1/1/true');
select t.eq('...and one push went to Sam', (select count(*)::int from push_outbox where recipient_id = t.u(1)), 1);
select t.eq('...of kind friend_joined', (select kind from push_outbox where recipient_id = t.u(1)), 'friend_joined');
select t.eq('...titled with the joiner''s name', (select title from push_outbox where recipient_id = t.u(1)), 'Maya connected with you');
select t.eq('...with the spec body', (select body from push_outbox where recipient_id = t.u(1)), 'You two are connected.');
select t.eq('...data names the joiner for the tap',
  (select data::text from push_outbox where recipient_id = t.u(1)),
  jsonb_build_object('kind', 'friend_joined', 'user_id', t.u(2))::text);
select t.eq('...expiring 24 hours later', (select extract(epoch from expires_at - created_at)::int from push_outbox where recipient_id = t.u(1)), 86400);

select t.eq('a double tap answers already', t.accept(t.u(2), :'sam_token'), 'already');
select t.eq('...and preview agrees', t.preview(t.u(2), :'sam_token'), 'already');
select t.eq('...still one friendship', t.pair(t.u(1), t.u(2)), 1);
select t.eq('...no second count', (select token_accepts from friend_links where user_id = t.u(1)), 1);
select t.eq('...no second push', (select count(*)::int from push_outbox where recipient_id = t.u(1)), 1);
select t.eq('already names the inviter for the Accept screen',
  t.scalar(format('select accept_friend_link(%L) ->> ''display_name''', :'sam_token'), t.u(2)), 'Sam');

-- Two people accepting each other's links end with one row, and the second answers already.
select t.link(t.u(3)) as leo_token \gset
select t.eq('Jalen accepts Leo''s link', t.accept(t.u(4), :'leo_token'), 'valid');
select t.eq('Leo then accepts Jalen''s link: already', t.accept(t.u(3), t.link(t.u(4))), 'already');
select t.eq('...one friendship for the pair', t.pair(t.u(3), t.u(4)), 1);
select t.eq('...and one push, to Leo', (select count(*)::int from push_outbox where recipient_id in (t.u(3), t.u(4))), 1);

select t.eq('a deleted account cannot accept',
  (t.call(format('select accept_friend_link(%L)', :'sam_token'), t.u(6))).hint, 'FC_ACCOUNT_DELETED');
select t.eq('signed out cannot accept',
  (t.call(format('select accept_friend_link(%L)', :'sam_token'), null)).hint, 'FC_NOT_SIGNED_IN');
select t.eq('anon cannot accept',
  (t.call(format('select accept_friend_link(%L)', :'sam_token'), null, 'anon')).sqlstate, '42501');

-- ===========================================================================
-- 4. Reset: the old link dies, friends stay, the count starts over.
-- ===========================================================================
select t.scalar('select reset_friend_link() ->> ''token''', t.u(1)) as sam_token2 \gset
select t.ok('reset returns a different 22-character token', :'sam_token2' <> :'sam_token' and :'sam_token2' ~ '^[A-Za-z0-9_-]{22}$');
select t.eq('the old token is dead for a stranger', t.preview(t.u(5), :'sam_token'), 'dead');
select t.eq('...and for a friend already connected (nothing to tell them)', t.preview(t.u(2), :'sam_token'), 'dead');
select t.eq('...and accept agrees', t.accept(t.u(5), :'sam_token'), 'dead');
select t.eq('the new token works', t.preview(t.u(5), :'sam_token2'), 'valid');
select t.eq('a reset counts', (select mint_count from friend_links where user_id = t.u(1)), 2);
select t.eq('...and zeroes the cap count but not the lifetime one',
  (select token_accepts || '/' || accept_count from friend_links where user_id = t.u(1)), '0/1');
select t.eq('a reset removed no friendship', t.pair(t.u(1), t.u(2)), 1);
select t.eq('a reset before any link mints the first one',
  (select length(t.scalar('select reset_friend_link() ->> ''token''', t.u(5)))), 22);
select t.eq('...as mint 1', (select mint_count from friend_links where user_id = t.u(5)), 1);
select t.eq('signed out cannot reset', (t.call('select reset_friend_link()', null)).hint, 'FC_NOT_SIGNED_IN');
select t.eq('anon cannot reset', (t.call('select reset_friend_link()', null, 'anon')).sqlstate, '42501');
select t.eq('a deleted account cannot reset', (t.call('select reset_friend_link()', t.u(6))).hint, 'FC_ACCOUNT_DELETED');

-- ===========================================================================
-- 5. Every dead cause, with preview and accept agreeing.
-- ===========================================================================
create or replace function t.same_answer(p_uid uuid, p_token text, p_want text) returns boolean language sql as $$
  select t.preview(p_uid, p_token) = p_want and t.accept(p_uid, p_token) = p_want
$$;

-- (a) unknown and (b) reset were covered above. (c) a deleted owner.
select t.link(t.u(7)) as cleo_token \gset
update users set deleted_at = now() where id = t.u(7);
select t.ok('an owner who is no longer active: the link is dead, preview and accept alike',
  t.same_answer(t.u(5), :'cleo_token', 'dead'));
select t.eq('...and nothing was connected', t.pair(t.u(5), t.u(7)), 0);
update users set deleted_at = null where id = t.u(7);

-- (d) a caller the owner removed (Mika joins, then Sam removes Mika).
select t.eq('Mika connects with Sam', t.accept(t.u(8), :'sam_token2'), 'valid');
select t.eq('Sam removes Mika', t.scalar('select remove_friend(''' || t.u(8) || ''') ->> ''removed''', t.u(1)), 'true');
select t.ok('Mika now reads Sam''s link as dead, preview and accept alike', t.same_answer(t.u(8), :'sam_token2', 'dead'));
select t.eq('...nothing was connected', t.pair(t.u(1), t.u(8)), 0);
select t.scalar('select reset_friend_link() ->> ''token''', t.u(1)) as sam_token3 \gset
select t.ok('...and still dead after Sam resets', t.same_answer(t.u(8), :'sam_token3', 'dead'));
select t.ok('...while a stranger reads the same link as valid', t.preview(t.u(5), :'sam_token3') = 'valid');

-- (e) the cap: the 50th accept works, the 51st is dead, a reset starts over.
update friend_links set token_accepts = 49 where user_id = t.u(1);
select t.eq('the 50th accept works', t.accept(t.u(5), :'sam_token3'), 'valid');
select t.eq('...the count is 50', (select token_accepts from friend_links where user_id = t.u(1)), 50);
insert into users(id, display_name) values (t.u(9), 'Fiftyfirst');
select t.ok('the 51st is dead, preview and accept alike', t.same_answer(t.u(9), :'sam_token3', 'dead'));
select t.eq('...and not connected', t.pair(t.u(1), t.u(9)), 0);
select t.eq('someone already connected still reads already at the cap', t.preview(t.u(5), :'sam_token3'), 'already');
select t.scalar('select reset_friend_link() ->> ''token''', t.u(1)) as sam_token4 \gset
select t.eq('a reset starts the cap over', t.accept(t.u(9), :'sam_token4'), 'valid');

-- ===========================================================================
-- 6. my_friends: who, newest first, never a deleted account.
-- ===========================================================================
select t.eq('Sam''s friends are Fiftyfirst, Arlo and Maya, newest first',
  t.scalar('select string_agg(display_name, '','' order by connected_at desc, id) from my_friends()', t.u(1)), 'Fiftyfirst,Arlo,Maya');
select t.eq('...as the function orders them',
  t.scalar('select string_agg(display_name, '','') from my_friends()', t.u(1)), 'Fiftyfirst,Arlo,Maya');
select t.eq('Maya has one friend, Sam', t.scalar('select string_agg(display_name, '','') from my_friends()', t.u(2)), 'Sam');
select t.eq('...with an id', t.scalar('select id::text from my_friends()', t.u(2)), t.u(1)::text);
select t.eq('a stranger has none', t.scalar('select count(*)::text from my_friends()', t.u(7)), '0');
update users set deleted_at = now() where id = t.u(9);
select t.eq('a friend whose account was just deleted is not listed',
  t.scalar('select string_agg(display_name, '','' order by display_name) from my_friends()', t.u(1)), 'Arlo,Maya');
update users set deleted_at = null where id = t.u(9);
select t.eq('signed out cannot list', (t.call('select * from my_friends()', null)).hint, 'FC_NOT_SIGNED_IN');
select t.eq('anon cannot list', (t.call('select * from my_friends()', null, 'anon')).sqlstate, '42501');
select t.eq('a deleted account cannot list', (t.call('select * from my_friends()', t.u(6))).hint, 'FC_ACCOUNT_DELETED');

-- ===========================================================================
-- 7. What a friendship grants -- and what it does not.
-- ===========================================================================
-- Sam hosts a plan with Maya only. Leo hosts one and hides Maya from nothing. Arlo is Sam's friend
-- and on no plan of his. A third plan of Sam's hides Arlo.
\set SAMPLAN 90000000-0000-0000-0000-0000000000a1
\set HIDDEN 90000000-0000-0000-0000-0000000000a2
insert into proposals(id, title, window_start, window_end, created_by, distribution)
values (:'SAMPLAN', 'Brunch', now() + interval '1 day', now() + interval '14 days', t.u(1),
        jsonb_build_object('mode', 'newGroup', 'recipientIDs', jsonb_build_array(t.u(1), t.u(2))));
insert into proposals(id, title, window_start, window_end, created_by, distribution, hidden_from)
values (:'HIDDEN', 'Surprise', now() + interval '1 day', now() + interval '14 days', t.u(1),
        jsonb_build_object('mode', 'newGroup', 'recipientIDs', jsonb_build_array(t.u(1), t.u(2))),
        array[t.u(5)]::uuid[]);
insert into busy_blocks(user_id, range, visibility, hidden_from)
values (t.u(1), tstzrange(now() + interval '3 days', now() + interval '3 days 2 hours', '[)'), 'stealth', array[t.u(5)]::uuid[]);

select t.eq('a friend (Arlo) reads Sam''s name', t.rows(format('select 1 from users where id = %L', t.u(1)), t.u(5)), 1);
select t.eq('...and Sam reads Arlo''s', t.rows(format('select 1 from users where id = %L', t.u(5)), t.u(1)), 1);
select t.eq('a stranger (Jalen) reads neither Sam''s row', t.rows(format('select 1 from users where id = %L', t.u(1)), t.u(4)), 0);
select t.eq('...nor Arlo''s', t.rows(format('select 1 from users where id = %L', t.u(5)), t.u(4)), 0);
select t.eq('a friend reads the name and avatar columns',
  t.scalar(format('select display_name from users where id = %L', t.u(1)), t.u(5)), 'Sam');
select t.eq('Arlo, a friend who is not a recipient, reads none of Sam''s plans',
  t.rows('select 1 from proposals', t.u(5)), 0);
select t.eq('...and Sam''s plan reads zero rows by id', t.rows(format('select 1 from proposals where id = %L', :'SAMPLAN'), t.u(5)), 0);
select t.eq('...no places', t.rows('select 1 from proposal_places', t.u(5)), 0);
select t.eq('...no votes', t.rows('select 1 from place_votes', t.u(5)), 0);
select t.eq('...no tag alongs', t.rows('select 1 from tag_alongs', t.u(5)), 0);
select t.eq('hidden_from still answers "no such plan" to a friend hidden from it',
  (t.call(format('select join_proposal(%L)', :'HIDDEN'), t.u(5))).hint, 'FC_NOT_FOUND');
select t.ok('...byte for byte like a plan that does not exist',
  (select r1.sqlstate = r2.sqlstate and r1.hint = r2.hint and r1.message = r2.message
     from t.call(format('select join_proposal(%L)', :'HIDDEN'), t.u(5)) r1,
          t.call('select join_proposal(''90000000-0000-0000-0000-0000000000ff'')', t.u(5)) r2));
-- Every signed-in person already reads every Busy block as a plain block; friendship adds a name
-- beside it and not one row more.
select t.eq('a friend reads when a Busy block is, as a plain block',
  t.rows(format('select range from busy_blocks where user_id = %L', t.u(1)), t.u(5)), 1);
select t.eq('...exactly as much as a stranger does',
  t.rows(format('select range from busy_blocks where user_id = %L', t.u(1)), t.u(4)), 1);
select t.ok('...but cannot select its hidden columns',
  not t.can_select('busy_blocks', 'hidden_from') and not t.can_select('busy_blocks', 'source_proposal_id'));
select t.ok('...nor a plan''s hidden_from', not t.can_select('proposals', 'hidden_from'));

-- ===========================================================================
-- 8. Poking: through friendship, through a plan, never after a removal.
-- ===========================================================================
create or replace function t.poke(p_from uuid, p_to uuid) returns t.outcome language sql as $$
  select t.call(format('select send_poke(%L)', p_to), p_from)
$$;
select t.eq('friends who share no plan can poke', (t.poke(t.u(5), t.u(1))).sqlstate, '00000');
select t.eq('...the other way too', (t.poke(t.u(1), t.u(5))).sqlstate, '00000');
select t.eq('strangers still cannot', (t.poke(t.u(4), t.u(1))).hint, 'FC_NOT_FRIEND');
select t.eq('the refusal reads "friends" and nothing about plans',
  (t.poke(t.u(4), t.u(1))).message, 'you can only poke friends');
select t.eq('Sam can poke a friend (Fiftyfirst) with no shared plan', (t.poke(t.u(1), t.u(9))).sqlstate, '00000');
update users set deleted_at = now() where id = t.u(9);
select t.eq('...once that friend is deleted: the same refusal as a stranger', (t.poke(t.u(1), t.u(9))).hint, 'FC_NOT_FRIEND');
update users set deleted_at = null where id = t.u(9);
delete from push_outbox where kind = 'poke'; delete from pokes;

select t.eq('Sam removes Arlo', t.scalar(format('select remove_friend(%L) ->> ''removed''', t.u(5)), t.u(1)), 'true');
select t.eq('a poke from the remover is refused', (t.poke(t.u(1), t.u(5))).hint, 'FC_NOT_FRIEND');
select t.eq('...and from the removed person', (t.poke(t.u(5), t.u(1))).hint, 'FC_NOT_FRIEND');
select t.eq('a removed friend loses the name', t.rows(format('select 1 from users where id = %L', t.u(1)), t.u(5)), 0);
select t.eq('...both ways', t.rows(format('select 1 from users where id = %L', t.u(5)), t.u(1)), 0);

-- A shared plan still works as the other door, after a removal.
select t.eq('Maya, still on Sam''s plan, can poke Sam', (t.poke(t.u(2), t.u(1))).sqlstate, '00000');
select t.eq('Sam removes Maya: the friendship goes', t.scalar(format('select remove_friend(%L) ->> ''removed''', t.u(2)), t.u(1)), 'true');
select t.eq('...but the shared plan still lets them poke', (t.poke(t.u(1), t.u(2))).sqlstate, '00000');
select t.eq('...and read each other''s names', t.rows(format('select 1 from users where id = %L', t.u(2)), t.u(1)), 1);
select t.eq('a poke already sent stays in the inbox',
  (select count(*)::int from pokes where from_user = t.u(2) and to_user = t.u(1)), 1);
select t.eq('...and Sam can still read it', t.rows('select 1 from pokes', t.u(1)) >= 1, true);

-- ===========================================================================
-- 9. Removing.
-- ===========================================================================
select t.eq('removing a non-friend reports nothing removed',
  t.scalar(format('select remove_friend(%L) ->> ''removed''', t.u(4)), t.u(1)), 'false');
select t.eq('...and writes no record', (select count(*)::int from friend_removals where removed = t.u(4)), 0);
select t.eq('removing yourself writes nothing',
  t.scalar(format('select remove_friend(%L) ->> ''removed''', t.u(1)), t.u(1)), 'false');
select t.eq('removing nobody writes nothing', t.scalar('select remove_friend(null) ->> ''removed''', t.u(1)), 'false');
select t.eq('removing an id that never existed writes nothing',
  t.scalar('select remove_friend(''00000000-0000-0000-0000-0000000000ee'') ->> ''removed''', t.u(1)), 'false');
select t.eq('removing twice is a no-op the second time',
  t.scalar(format('select remove_friend(%L) ->> ''removed''', t.u(5)), t.u(1)), 'false');
select t.eq('...one record', (select count(*)::int from friend_removals where remover = t.u(1) and removed = t.u(5)), 1);
select t.eq('the removed person''s own removal call changes nothing',
  t.scalar(format('select remove_friend(%L) ->> ''removed''', t.u(1)), t.u(5)), 'false');
select t.eq('...so no record runs the other way', (select count(*)::int from friend_removals where remover = t.u(5)), 0);
select t.ok('the removed person (Arlo) reads Sam''s current link as dead', t.same_answer(t.u(5), t.link(t.u(1)), 'dead'));

-- The remover reconnects by accepting the other person's link, which clears the record.
select t.eq('Sam accepts Arlo''s link', t.accept(t.u(1), t.link(t.u(5))), 'valid');
select t.eq('...they are friends again', t.pair(t.u(1), t.u(5)), 1);
select t.eq('...the record is gone', (select count(*)::int from friend_removals where remover = t.u(1) and removed = t.u(5)), 0);
select t.eq('...and Arlo reads Sam''s link as already', t.preview(t.u(5), t.link(t.u(1))), 'already');
select t.eq('...Arlo can poke Sam again', (t.poke(t.u(5), t.u(1))).sqlstate, '00000');
select t.eq('a friend can be removed by either side',
  t.scalar(format('select remove_friend(%L) ->> ''removed''', t.u(1)), t.u(5)), 'true');
select t.eq('...and the other side is the removed one',
  (select count(*)::int from friend_removals where remover = t.u(5) and removed = t.u(1)), 1);
select t.eq('...who now reads that remover''s link as dead', t.preview(t.u(1), t.link(t.u(5))), 'dead');
delete from friend_removals; delete from push_outbox; delete from pokes;

-- ===========================================================================
-- 10. Deleting an account.
-- ===========================================================================
select t.link(t.u(4)) as jalen_token \gset
select t.eq('Leo accepts Jalen''s link, with a removal on file the other way',
  t.accept(t.u(2), :'jalen_token'), 'valid');
insert into friend_removals(remover, removed) values (t.u(4), t.u(5)), (t.u(3), t.u(4));
select t.eq('before: Jalen has friends, a link and removal records',
  (select count(*)::int from friendships where t.u(4) in (user_a, user_b))
  || '/' || (select count(*)::int from friend_links where user_id = t.u(4))
  || '/' || (select count(*)::int from friend_removals where t.u(4) in (remover, removed)), '2/1/2');
select t.scalar('select delete_account()::text', t.u(4)) is not null as deleted;
select t.eq('after deletion: no friendship', (select count(*)::int from friendships where t.u(4) in (user_a, user_b)), 0);
select t.eq('...no link', (select count(*)::int from friend_links where user_id = t.u(4)), 0);
select t.eq('...no removal record, either direction', (select count(*)::int from friend_removals where t.u(4) in (remover, removed)), 0);
select t.eq('...the token is dead for everyone', t.preview(t.u(5), :'jalen_token'), 'dead');
select t.eq('...and nobody lists them as a friend',
  t.scalar('select count(*)::text from my_friends() where id = ''' || t.u(4) || '''', t.u(3)), '0');
select t.eq('a second deletion changes nothing and still succeeds',
  (t.call('select delete_account()', t.u(4))).sqlstate, '00000');
select t.eq('...and an accept for the deleted account is refused', (t.call(format('select accept_friend_link(%L)', t.link(t.u(5))), t.u(4))).hint, 'FC_ACCOUNT_DELETED');
select t.eq('a person with no holds is still locked out by the deletion lock set',
  (select prosrc like '%coalesce(array_agg(distinct s.user_id), ''{}'') || v_uid%' from pg_proc where proname = 'delete_account'), true);

-- ===========================================================================
-- 11. No client reaches the friend tables, and the self-check says so.
-- ===========================================================================
select t.eq('authenticated cannot read friendships', (t.call('select * from friendships', t.u(1))).sqlstate, '42501');
select t.eq('authenticated cannot read friend_links (no one reads a token)', (t.call('select * from friend_links', t.u(1))).sqlstate, '42501');
select t.eq('authenticated cannot read friend_removals', (t.call('select * from friend_removals', t.u(1))).sqlstate, '42501');
select t.eq('anon cannot read friendships', (t.call('select * from friendships', null, 'anon')).sqlstate, '42501');
select t.eq('anon cannot read friend_links', (t.call('select * from friend_links', null, 'anon')).sqlstate, '42501');
select t.eq('anon cannot read friend_removals', (t.call('select * from friend_removals', null, 'anon')).sqlstate, '42501');
select t.eq('authenticated cannot insert a friendship',
  (t.call(format('insert into friendships(user_a, user_b) values (%L, %L)', t.u(1), t.u(2)), t.u(1))).sqlstate, '42501');
select t.eq('...nor edit a token',
  (t.call(format('update friend_links set token = %L', repeat('B', 22)), t.u(1))).sqlstate, '42501');
select t.eq('...nor delete a removal record', (t.call('delete from friend_removals', t.u(1))).sqlstate, '42501');
select t.ok('row level security is on for all three',
  (select count(*) = 3 from pg_class c where c.relnamespace = 'public'::regnamespace and c.relrowsecurity
      and c.relname in ('friendships', 'friend_links', 'friend_removals')));
select t.eq('...and no policy exists on any of them',
  (select count(*)::int from pg_policies where schemaname = 'public' and tablename in ('friendships', 'friend_links', 'friend_removals')), 0);
select t.ok('anon is refused on every new function',
  (select bool_and(not has_function_privilege('anon', f, 'EXECUTE'))
     from unnest(array['friend_link()', 'reset_friend_link()', 'preview_friend_link(text)', 'accept_friend_link(text)',
                       'remove_friend(uuid)', 'my_friends()', 'friendcal_is_friend(uuid)']) f));
select t.ok('the internal helpers belong to no client',
  (select bool_and(not has_function_privilege('authenticated', f, 'EXECUTE') and not has_function_privilege('anon', f, 'EXECUTE'))
     from unnest(array['friendcal_new_friend_token()', 'friendcal_friend_link_answer(text, uuid)',
                       'friendcal_friend_link_json(text, uuid)', 'friendcal_friends_selfcheck()']) f));
select t.eq('friendcal_is_friend: null is false', t.scalar('select friendcal_is_friend(null)::text', t.u(2)), 'false');
select t.eq('...a stranger is false', t.scalar(format('select friendcal_is_friend(%L)::text', t.u(7)), t.u(2)), 'false');
select t.eq('...signed out is false', t.scalar(format('select friendcal_is_friend(%L)::text', t.u(1)), null), 'false');
select t.eq('...a friend is true', t.scalar(format('select friendcal_is_friend(%L)::text', t.u(9)), t.u(1)), 'true');

select t.ok('the self-check passes as installed', not t.check_fails('select 1'));
select t.ok('...fails if a client can read friendships', t.check_fails('grant select on friendships to authenticated'));
select t.ok('...fails if a client can write friend_links', t.check_fails('grant update (token) on friend_links to authenticated'));
select t.ok('...fails if anon can read friend_removals', t.check_fails('grant select on friend_removals to anon'));
select t.ok('...fails if row level security goes off', t.check_fails('alter table friend_links disable row level security'));
select t.ok('...fails if a policy appears', t.check_fails('create policy leak on friendships for select using (true)'));
select t.ok('...fails if anon can accept a link', t.check_fails('grant execute on function accept_friend_link(text) to anon'));
select t.ok('...fails if public can call my_friends', t.check_fails('grant execute on function my_friends() to public'));
select t.ok('...fails if authenticated can call the answer helper',
  t.check_fails('grant execute on function friendcal_friend_link_answer(text, uuid) to authenticated'));
select t.ok('...fails if authenticated loses a client function', t.check_fails('revoke execute on function remove_friend(uuid) from authenticated'));

-- ===========================================================================
-- 12. Structure: the gate is read after the lock, and the rules stay in one place.
-- ===========================================================================
select t.ok('send_poke takes the user lock before it reads friendship',
  (select position('friendcal_lock_users' in prosrc) > 0
      and position('friendcal_lock_users' in prosrc) < position('friendcal_is_friend' in prosrc)
     from pg_proc where proname = 'send_poke'));
select t.ok('accept, remove and reset take the shared user lock',
  (select bool_and(prosrc like '%friendcal_lock_users%') from pg_proc
    where proname in ('accept_friend_link', 'remove_friend', 'reset_friend_link', 'friend_link')));
select t.ok('accept re-reads the answer after it takes the lock',
  (select t.occurrences(prosrc, 'friendcal_friend_link_answer') = 2
      and position('friendcal_lock_users' in prosrc) > position('friendcal_friend_link_answer' in prosrc)
     from pg_proc where proname = 'accept_friend_link'));
select t.ok('push_outbox accepts friend_joined and the older kinds',
  (select pg_get_constraintdef(oid) like '%friend_joined%' and pg_get_constraintdef(oid) like '%poke%'
          and pg_get_constraintdef(oid) like '%tag_along%'
     from pg_constraint where conname = 'push_outbox_kind'));
select t.eq('the friend tables are ordered by a check', (select count(*)::int from pg_constraint where conname = 'friendships_ordered'), 1);
select t.eq('...and an unordered pair is refused',
  (t.call(format('insert into friendships(user_a, user_b) values (%L, %L)', t.u(9), t.u(8)), null, 'postgres')).sqlstate, '23514');

do $$ begin raise notice 'friends tests: all passed'; end $$;
