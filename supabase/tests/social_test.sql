-- Poke, Tag along and the push outbox (social.sql).
-- Run with scripts/test-sql.sh. Helpers come from tests/helpers.sql.
--
-- Three claims carry this file. A poke is ONE row whose state only ever moves forward, however
-- many times it is sent, tapped or answered. Neither RPC can be used to learn something the caller
-- could not already read: who exists, who is hidden from a plan, whose poke an id belongs to. And
-- every push that leaves is written in the same transaction as the thing it announces.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

-- u1 Sam hosts. u2 Maya and u3 Leo are on Sam's plans. u4 is Jalen: on the open plan, hidden from
-- the surprise. u5 Arlo shares no plan with anyone. u6 has deleted their account. u7 Cleo holds the
-- link to the locked plan but was not free when it locked. u8 is busy during the locked window.
insert into users(id, display_name) values
  (t.u(1), 'Sam'), (t.u(2), 'Maya'), (t.u(3), 'Leo'), (t.u(4), 'Jalen'),
  (t.u(5), 'Arlo'), (t.u(6), 'Gone'), (t.u(7), 'Cleo'), (t.u(8), 'Mika');
update users set deleted_at = now(), display_name = 'Deleted account' where id = t.u(6);

\set OPEN 90000000-0000-0000-0000-000000000001
\set SURPRISE 90000000-0000-0000-0000-000000000002
\set LOCKED 90000000-0000-0000-0000-000000000003
\set OVER 90000000-0000-0000-0000-000000000004
\set GHOST 90000000-0000-0000-0000-0000000000ff
\set NOPOKE 91000000-0000-0000-0000-0000000000ff

insert into proposals(id, title, window_start, window_end, created_by, distribution)
values (:'OPEN', 'Brunch', now() + interval '1 day', now() + interval '14 days', t.u(1),
        jsonb_build_object('mode', 'newGroup',
          'recipientIDs', jsonb_build_array(t.u(1), t.u(2), t.u(3), t.u(4), t.u(6), t.u(8))));
insert into proposals(id, title, window_start, window_end, created_by, distribution, hidden_from)
values (:'SURPRISE', 'Surprise for Jalen', now() + interval '1 day', now() + interval '14 days', t.u(1),
        jsonb_build_object('mode', 'newGroup', 'recipientIDs', jsonb_build_array(t.u(1), t.u(2), t.u(4))),
        array[t.u(4)]::uuid[]);
insert into proposals(id, title, window_start, window_end, created_by, distribution, status,
                      locked_date, locked_end, locked_attendee_ids, locked_at)
values (:'LOCKED', 'Tacos', now() - interval '1 day', now() + interval '10 days', t.u(1),
        jsonb_build_object('mode', 'newGroup', 'recipientIDs', jsonb_build_array(t.u(1), t.u(2), t.u(7))),
        'locked', now() + interval '2 days', now() + interval '2 days 2 hours',
        array[t.u(1), t.u(2)]::uuid[], now());
insert into proposals(id, title, window_start, window_end, created_by, distribution, status,
                      locked_date, locked_end, locked_attendee_ids, locked_at)
values (:'OVER', 'Last week', now() - interval '10 days', now() - interval '1 day', t.u(1),
        jsonb_build_object('mode', 'newGroup', 'recipientIDs', jsonb_build_array(t.u(1), t.u(7))),
        'locked', now() - interval '3 days', now() - interval '3 days' + interval '2 hours',
        array[t.u(1)]::uuid[], now() - interval '4 days');
-- Mika already has something across the Tacos window.
insert into busy_blocks(user_id, range, visibility)
values (t.u(8), tstzrange(now() + interval '2 days 1 hour', now() + interval '2 days 3 hours', '[)'), 'public');

create or replace function t.poke(p_from uuid, p_to uuid, p_plan uuid default null) returns t.outcome
language sql as $$
  select t.call(format('select send_poke(%L, %L)', p_to, p_plan), p_from)
$$;
create or replace function t.poke_field(p_from uuid, p_to uuid, p_field text, p_plan uuid default null) returns text
language sql as $$
  select t.scalar(format('select send_poke(%L, %L) ->> %L', p_to, p_plan, p_field), p_from)
$$;

-- ===========================================================================
-- 1. Who can poke whom.
-- ===========================================================================
select t.eq('signed out cannot poke', (t.call(format('select send_poke(%L)', t.u(2)), null)).hint, 'FC_NOT_SIGNED_IN');
select t.eq('you cannot poke yourself', (t.poke(t.u(1), t.u(1))).hint, 'FC_SELF_POKE');
select t.eq('someone you share no plan with is not a friend', (t.poke(t.u(1), t.u(5))).hint, 'FC_NOT_FRIEND');
select t.eq('a deleted account cannot poke', (t.poke(t.u(6), t.u(1))).hint, 'FC_ACCOUNT_DELETED');

-- No enumeration: a stranger, a deleted account and an id that was never issued are one refusal.
select t.ok('stranger, tombstone and made-up id are refused identically',
  (select r1.sqlstate = r2.sqlstate and r2.sqlstate = r3.sqlstate
          and r1.hint = r2.hint and r2.hint = r3.hint
          and r1.message = r2.message and r2.message = r3.message
     from t.poke(t.u(1), t.u(5)) r1, t.poke(t.u(1), t.u(6)) r2,
          t.poke(t.u(1), '90000000-0000-0000-0000-0000000000aa'::uuid) r3));
select t.eq('none of those refusals wrote a poke', (select count(*)::int from pokes), 0);
select t.eq('...or a push', (select count(*)::int from push_outbox), 0);

-- Sharing only a plan one of you is hidden from is not sharing a plan.
update proposals set distribution = jsonb_set(distribution, '{recipientIDs}', distribution -> 'recipientIDs' || to_jsonb(t.u(5)::text))
 where id = :'SURPRISE';
select t.eq('a plan Jalen is hidden from does not make Arlo his friend', (t.poke(t.u(5), t.u(4))).hint, 'FC_NOT_FRIEND');
select t.eq('...though it makes Arlo and Sam friends', (t.poke(t.u(5), t.u(1))).sqlstate, '00000');
delete from push_outbox; delete from pokes;

-- ===========================================================================
-- 2. One live poke per pair, for exactly one hour.
-- ===========================================================================
select t.eq('a poke is new the first time', t.poke_field(t.u(1), t.u(2), 'is_new'), 'true');
select t.eq('it lasts one hour',
  (select extract(epoch from (expires_at - created_at))::int from pokes where from_user = t.u(1) and to_user = t.u(2)), 3600);
select t.eq('it queued one push for Maya',
  (select count(*)::int from push_outbox where recipient_id = t.u(2) and kind = 'poke'), 1);
select t.eq('the push says who', (select title from push_outbox where recipient_id = t.u(2)), 'Sam poked you');
select t.eq('the push expires with the poke',
  (select o.expires_at = p.expires_at from push_outbox o, pokes p where o.recipient_id = t.u(2) and p.to_user = t.u(2)), true);
select t.eq('the push carries the poke id for the tap',
  (select o.data ->> 'poke_id' from push_outbox o where o.recipient_id = t.u(2)),
  (select id::text from pokes where to_user = t.u(2)));

select t.eq('poking again while it is live is not new', t.poke_field(t.u(1), t.u(2), 'is_new'), 'false');
select t.eq('...and returns the same poke',
  t.poke_field(t.u(1), t.u(2), 'id'), (select id::text from pokes where from_user = t.u(1) and to_user = t.u(2)));
select t.eq('...and there is still one row', (select count(*)::int from pokes where from_user = t.u(1) and to_user = t.u(2)), 1);
select t.eq('...and still one push', (select count(*)::int from push_outbox where recipient_id = t.u(2)), 1);
select t.eq('a different friend is a different poke', t.poke_field(t.u(1), t.u(3), 'is_new'), 'true');

-- An hour on: the old one is over, so a new one may go.
update pokes set created_at = now() - interval '61 minutes', expires_at = now() - interval '1 minute'
 where from_user = t.u(1) and to_user = t.u(2);
select t.eq('after it expires a new poke may go', t.poke_field(t.u(1), t.u(2), 'is_new'), 'true');
select t.eq('...as a second row', (select count(*)::int from pokes where from_user = t.u(1) and to_user = t.u(2)), 2);

-- ===========================================================================
-- 3. Acknowledging: the recipient only, once, and never after the hour.
-- ===========================================================================
select id as live_poke from pokes where from_user = t.u(1) and to_user = t.u(2) and expires_at > now() \gset
select id as dead_poke from pokes where from_user = t.u(1) and to_user = t.u(2) and expires_at <= now() \gset

select t.eq('the sender cannot acknowledge their own poke',
  (t.call(format('select ack_poke(%L)', :'live_poke'), t.u(1))).hint, 'FC_POKE_NOT_FOUND');
select t.ok('someone else''s poke reads exactly like a poke that does not exist',
  (select r1.sqlstate = r2.sqlstate and r1.hint = r2.hint and r1.message = r2.message
     from t.call(format('select ack_poke(%L)', :'live_poke'), t.u(3)) r1,
          t.call(format('select ack_poke(%L)', :'NOPOKE'), t.u(3)) r2));
select t.eq('a push tap acknowledges',
  t.scalar(format('select ack_poke(%L, ''push'') ->> ''ack_via''', :'live_poke'), t.u(2)), 'push');
select acknowledged_at as first_ack from pokes where id = :'live_poke' \gset
select t.eq('a second acknowledgement keeps the first',
  t.scalar(format('select ack_poke(%L, ''app'') ->> ''ack_via''', :'live_poke'), t.u(2)), 'push');
select t.eq('...and its time', (select acknowledged_at from pokes where id = :'live_poke'), :'first_ack'::timestamptz);
select t.eq('an unknown via is recorded as the app, not trusted',
  t.scalar(format('select ack_poke(%L, ''poke_back'') ->> ''ack_via''',
                  (select id from pokes where from_user = t.u(1) and to_user = t.u(3))), t.u(3)), 'app');
select t.eq('acknowledging an expired poke succeeds',
  (t.call(format('select ack_poke(%L)', :'dead_poke'), t.u(2))).sqlstate, '00000');
select t.ok('...and leaves it expired, not seen', (select acknowledged_at is null from pokes where id = :'dead_poke'));
select t.eq('once acknowledged, the sender may poke again', t.poke_field(t.u(1), t.u(2), 'is_new'), 'true');

-- ===========================================================================
-- 4. Poking back answers theirs.
-- ===========================================================================
select t.eq('Maya pokes Sam back', t.poke_field(t.u(2), t.u(1), 'is_new'), 'true');
select t.eq('...which acknowledges Sam''s live poke as a poke back',
  (select ack_via from pokes where from_user = t.u(1) and to_user = t.u(2) order by created_at desc limit 1), 'poke_back');
select t.eq('...and Sam now has one live poke from Maya',
  (select count(*)::int from pokes where from_user = t.u(2) and to_user = t.u(1) and acknowledged_at is null and expires_at > now()), 1);

-- ===========================================================================
-- 5. A plan is context, never a leak.
-- ===========================================================================
delete from push_outbox; delete from pokes;
select t.eq('a poke about a shared plan carries it', t.poke_field(t.u(1), t.u(3), 'proposal_id', :'OPEN'), :'OPEN');
select t.eq('...and the push names the plan',
  (select body from push_outbox where recipient_id = t.u(3)), 'About Brunch. Poke back before it fades in an hour.');
-- Sam pokes Jalen "about" the surprise Jalen is hidden from. The poke goes; the plan does not.
select t.eq('a poke about a plan the recipient is hidden from still goes', (t.poke(t.u(1), t.u(4), :'SURPRISE')).sqlstate, '00000');
select t.ok('...with no plan attached', (select proposal_id is null from pokes where to_user = t.u(4)));
select t.ok('...and a push that never names it',
  (select title || ' ' || body || ' ' || data::text not like '%Surprise%'
          and data::text not like '%' || :'SURPRISE' || '%' from push_outbox where recipient_id = t.u(4)));
select t.eq('a poke about a plan that does not exist still goes', (t.poke(t.u(2), t.u(3), :'GHOST')).sqlstate, '00000');
select t.ok('...as a plain poke', (select proposal_id is null from pokes where from_user = t.u(2) and to_user = t.u(3)));

-- ===========================================================================
-- 6. Reads: the two people on a poke, and nobody else. No client writes at all.
-- ===========================================================================
select t.eq('the sender reads their poke', t.rows('select 1 from pokes where to_user = ' || quote_literal(t.u(3)), t.u(1)), 1);
select t.eq('the recipient reads it', t.rows('select 1 from pokes where from_user = ' || quote_literal(t.u(1)), t.u(3)), 1);
select t.eq('a third friend reads none of Sam''s pokes',
  t.rows('select 1 from pokes where from_user = ' || quote_literal(t.u(1)), t.u(8)), 0);
select t.eq('a client cannot insert a poke',
  (t.call(format('insert into pokes(from_user, to_user, expires_at) values (%L, %L, now() + interval ''1 hour'')', t.u(8), t.u(1)), t.u(8))).sqlstate, '42501');
select t.eq('a client cannot acknowledge by writing the row',
  (t.call('update pokes set acknowledged_at = now(), ack_via = ''app''', t.u(3))).sqlstate, '42501');
select t.eq('a client cannot read the outbox', (t.call('select 1 from push_outbox', t.u(1))).sqlstate, '42501');
select t.eq('a client cannot read device tokens', (t.call('select 1 from device_tokens', t.u(1))).sqlstate, '42501');
select t.eq('a client cannot call the internal friend predicate',
  (t.call(format('select friendcal_share_plan(%L, %L)', t.u(1), t.u(4)), t.u(1))).sqlstate, '42501');
select t.eq('anon reads no pokes', (t.call('select 1 from pokes', null, 'anon')).sqlstate, '42501');

-- ===========================================================================
-- 7. Tag along.
-- ===========================================================================
delete from push_outbox;
select t.eq('signed out cannot tag along', (t.call(format('select tag_along(%L)', :'LOCKED'), null)).hint, 'FC_NOT_SIGNED_IN');
select t.eq('a plan still collecting times is not ready', (t.call(format('select tag_along(%L)', :'OPEN'), t.u(3))).hint, 'FC_NOT_LOCKED');
select t.eq('a plan that already happened is over', (t.call(format('select tag_along(%L)', :'OVER'), t.u(7))).hint, 'FC_PLAN_OVER');
select t.eq('a deleted account cannot tag along', (t.call(format('select tag_along(%L)', :'LOCKED'), t.u(6))).hint, 'FC_ACCOUNT_DELETED');

-- D12, on the new door: hidden and nonexistent are byte-identical, and identical to join_proposal's.
update proposals set hidden_from = array[t.u(4)]::uuid[] where id = :'LOCKED';
select t.ok('a hidden id is told exactly what a made-up link is told',
  (select r1.sqlstate = r2.sqlstate and r1.hint = r2.hint and r1.message = r2.message and r1.hint = 'FC_NOT_FOUND'
     from t.call(format('select tag_along(%L)', :'LOCKED'), t.u(4)) r1,
          t.call(format('select tag_along(%L)', :'GHOST'), t.u(4)) r2));
select t.ok('...and what join_proposal tells them',
  (select r1.sqlstate = r2.sqlstate and r1.hint = r2.hint and r1.message = r2.message
     from t.call(format('select tag_along(%L)', :'LOCKED'), t.u(4)) r1,
          t.call(format('select join_proposal(%L)', :'LOCKED'), t.u(4)) r2));

-- Someone already busy then is refused, and the refusal leaves nothing behind.
select t.eq('someone busy during the window is refused', (t.call(format('select tag_along(%L)', :'LOCKED'), t.u(8))).hint, 'FC_BUSY');
select t.eq('...with the SQLSTATE of the constraint that caught it', (t.call(format('select tag_along(%L)', :'LOCKED'), t.u(8))).sqlstate, '23P01');
select t.ok('...and the refusal does not print the clashing range',
  (select (t.call(format('select tag_along(%L)', :'LOCKED'), t.u(8))).message = 'you are already busy then'));
select t.ok('...and they are not on the plan',
  (select not (t.u(8) = any (locked_attendee_ids)) and not (distribution -> 'recipientIDs') ? t.u(8)::text
     from proposals where id = :'LOCKED'));
select t.eq('...and no push went', (select count(*)::int from push_outbox), 0);

-- Cleo was on the plan but not free at the lock. Now she is in.
select t.eq('a recipient who missed the lock tags along',
  t.scalar(format('select tag_along(%L) ->> ''already_in''', :'LOCKED'), t.u(7)), 'false');
select t.ok('she is an attendee', (select t.u(7) = any (locked_attendee_ids) from proposals where id = :'LOCKED'));
select t.eq('she is a recipient exactly once',
  (select count(*)::int from jsonb_array_elements_text((select distribution -> 'recipientIDs' from proposals where id = :'LOCKED')) e
    where e.value = t.u(7)::text), 1);
select t.eq('she has the plan''s Busy block, stamped with the plan',
  (select count(*)::int from busy_blocks b, proposals p
    where p.id = :'LOCKED' and b.user_id = t.u(7) and b.source_proposal_id = p.id
      and b.range = tstzrange(p.locked_date, p.locked_end, '[)')), 1);
select t.eq('it shows on her commitments by name',
  t.scalar('select plan_title from my_commitments(now()) where kind = ''locked''', t.u(7)), 'Tacos');
select t.eq('the host is told', (select title from push_outbox where recipient_id = t.u(1) and kind = 'tag_along'), 'Cleo is tagging along');
select t.eq('...which plan', (select body from push_outbox where recipient_id = t.u(1) and kind = 'tag_along'), 'They just joined Tacos.');
select t.eq('the host reads the tag along', t.rows('select 1 from tag_alongs where proposal_id = ' || quote_literal(:'LOCKED'), t.u(1)), 1);
select t.eq('someone not on the plan does not', t.rows('select 1 from tag_alongs', t.u(5)), 0);
select t.eq('a hidden id does not either', t.rows('select 1 from tag_alongs', t.u(4)), 0);

-- Idempotent.
select t.eq('a second tap says already in',
  t.scalar(format('select tag_along(%L) ->> ''already_in''', :'LOCKED'), t.u(7)), 'true');
select t.eq('...with one Busy block', (select count(*)::int from busy_blocks where user_id = t.u(7)), 1);
select t.eq('...one row', (select count(*)::int from tag_alongs where user_id = t.u(7)), 1);
select t.eq('...and one push', (select count(*)::int from push_outbox where kind = 'tag_along'), 1);

-- A link holder who was never on the plan may tag along too; the host tagging along tells nobody.
select t.eq('a link holder who shares nothing yet can tag along', (t.call(format('select tag_along(%L)', :'LOCKED'), t.u(5))).sqlstate, '00000');
select t.eq('...and can now read the plan', t.rows('select 1 from proposals where id = ' || quote_literal(:'LOCKED'), t.u(5)), 1);
update proposals set locked_attendee_ids = array_remove(locked_attendee_ids, t.u(1)) where id = :'LOCKED';
delete from push_outbox;
select t.eq('the host tags along to their own plan', (t.call(format('select tag_along(%L)', :'LOCKED'), t.u(1))).sqlstate, '00000');
select t.eq('...without a push to themselves', (select count(*)::int from push_outbox), 0);
select t.eq('a client cannot write a tag along directly',
  (t.call(format('insert into tag_alongs(proposal_id, user_id) values (%L, %L)', :'LOCKED', t.u(3)), t.u(3))).sqlstate, '42501');

-- ===========================================================================
-- 8. Device tokens.
-- ===========================================================================
\set TOKEN 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
select t.eq('a token registers', (t.call(format('select register_device(%L, ''sandbox'')', :'TOKEN'), t.u(2))).sqlstate, '00000');
select t.eq('...for the caller', (select user_id from device_tokens where token = :'TOKEN'), t.u(2));
select t.eq('registering it again is one row',
  (select (t.call(format('select register_device(%L, ''sandbox'')', upper(:'TOKEN')), t.u(2))).sqlstate), '00000');
select t.eq('...still one', (select count(*)::int from device_tokens), 1);
select t.eq('the same phone signing in as someone else moves the token',
  (select (t.call(format('select register_device(%L)', :'TOKEN'), t.u(3))).sqlstate), '00000');
select t.eq('...to them', (select user_id from device_tokens where token = :'TOKEN'), t.u(3));
select t.eq('...as production', (select environment from device_tokens where token = :'TOKEN'), 'production');
select t.eq('garbage is not a token', (t.call('select register_device(''not-a-token'')', t.u(2))).hint, 'FC_BAD_TOKEN');
select t.eq('an unknown environment is refused', (t.call(format('select register_device(%L, ''staging'')', :'TOKEN'), t.u(2))).hint, 'FC_BAD_TOKEN');
select t.eq('you cannot remove someone else''s token', (t.call(format('select unregister_device(%L)', :'TOKEN'), t.u(2))).sqlstate, '00000');
select t.eq('...it is still there', (select count(*)::int from device_tokens), 1);
select t.eq('you can remove your own', (t.call(format('select unregister_device(%L)', :'TOKEN'), t.u(3))).sqlstate, '00000');
select t.eq('...and it is gone', (select count(*)::int from device_tokens), 0);

-- ===========================================================================
-- 9. A deleted account stops receiving.
-- ===========================================================================
select t.eq('Leo registers a phone', (t.call(format('select register_device(%L)', :'TOKEN'), t.u(3))).sqlstate, '00000');
delete from push_outbox;
select t.eq('...and has a push queued', (t.poke(t.u(1), t.u(3))).sqlstate, '00000');
insert into push_outbox(recipient_id, kind, title, body, sent_at) values (t.u(3), 'poke', 'old', 'old', now());
select t.eq('Leo deletes his account', (t.call('select delete_account()', t.u(3))).sqlstate, '00000');
select t.eq('his token is gone', (select count(*)::int from device_tokens where user_id = t.u(3)), 0);
select t.eq('his unsent pushes are gone', (select count(*)::int from push_outbox where recipient_id = t.u(3) and sent_at is null), 0);
select t.eq('what was already sent stays as a record', (select count(*)::int from push_outbox where recipient_id = t.u(3)), 1);
select t.eq('and he can no longer be poked', (t.poke(t.u(1), t.u(3))).hint, 'FC_NOT_FRIEND');

-- ===========================================================================
-- 10. Drift guard: every refusal in these functions carries an FC_ hint.
-- ===========================================================================
select t.eq('every raise in ' || p.proname || ' carries an FC_ hint',
  t.occurrences(pg_get_functiondef(p.oid), 'raise exception'),
  t.occurrences(pg_get_functiondef(p.oid), 'hint = ''FC_'))
  from pg_proc p
 where p.proname in ('send_poke', 'ack_poke', 'tag_along', 'register_device', 'unregister_device');

-- ===========================================================================
-- Recipients stored the way the Swift client stores them: UPPERCASE uuid text. The creator is not
-- either recipient, so friendcal_share_plan and the plan lookup in send_poke can only succeed through
-- friendcal_has_recipient; tag_along's "already a recipient" test likewise. Ids are t.uh(n): t.u(n) is
-- all digits, so upper() of it is the same string and proves nothing.
--
-- Value: protects=a poke between two uppercase-stored recipients attaches the shared plan, and tag_along does not add a second spelling of an existing recipient; fails_when=either call goes back to a case-sensitive recipient test (the plan is silently not attached, or tag_along appends a duplicate); why_new=every fixture above stores all-digit ids that are identical in both cases; seam=none; no_claim=mixed-case ids (unsupported by design)
-- ===========================================================================
insert into users(id, display_name) values (t.uh(7), 'Hex7'), (t.uh(8), 'Hex8'), (t.uh(2), 'Hex2');
\set UPPLAN 90000000-0000-0000-0000-000000000005
\set UPLOCK 90000000-0000-0000-0000-000000000006
insert into proposals(id, title, window_start, window_end, created_by, distribution)
values (:'UPPLAN', 'Uppercase plan', now() + interval '1 day', now() + interval '14 days', t.u(1),
        jsonb_build_object('mode', 'newGroup', 'recipientIDs', jsonb_build_array(upper(t.uh(7)::text), upper(t.uh(8)::text))));
select t.eq('two uppercase-stored recipients can poke each other about their plan',
  t.poke_field(t.uh(7), t.uh(8), 'proposal_id', :'UPPLAN'), :'UPPLAN');
update proposals set hidden_from = array[t.uh(8)]::uuid[] where id = :'UPPLAN';
select t.eq('exclusion outranks uppercase membership in friendcal_share_plan',
  friendcal_share_plan(t.uh(7), t.uh(8)), false);

insert into proposals(id, title, window_start, window_end, created_by, distribution, status,
                      locked_date, locked_end, locked_attendee_ids, locked_at)
values (:'UPLOCK', 'Uppercase tacos', now() - interval '1 day', now() + interval '10 days', t.u(1),
        jsonb_build_object('mode', 'newGroup', 'recipientIDs', jsonb_build_array(upper(t.u(1)::text), upper(t.uh(2)::text))),
        'locked', now() + interval '5 days', now() + interval '5 days 2 hours',
        array[t.u(1)]::uuid[], now());
select t.eq('an uppercase-stored recipient tags along',
  t.scalar(format('select tag_along(%L) ->> ''already_in''', :'UPLOCK'), t.uh(2)), 'false');
select t.eq('...and is still listed once, not once per spelling',
  (select jsonb_array_length(distribution -> 'recipientIDs') from proposals where id = :'UPLOCK'), 2);
select t.eq('...and a second tap reports already_in',
  t.scalar(format('select tag_along(%L) ->> ''already_in''', :'UPLOCK'), t.uh(2)), 'true');

do $$ begin raise notice 'social tests: all passed'; end $$;
