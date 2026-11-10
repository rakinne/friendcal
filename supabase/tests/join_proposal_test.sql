-- join_proposal() and proposal_summaries: D12 exclusion is not a tell, and the forwarded link works.
-- Run with scripts/test-sql.sh. Helpers come from tests/helpers.sql.
--
-- The claim under test is a negative one, which is why it needs its own file: an excluded id holding
-- a real link must be unable to distinguish that link from a made-up one, on EVERY path -- the RPC,
-- the table, and the summary view. Anything that differs is a confirmation that the plan exists.
\set ON_ERROR_STOP 1
set client_min_messages = notice;

-- u1 hosts. u2 is invited. u3 holds a forwarded link and is welcome. u4 is Jalen: holds the same
-- forwarded link and is deliberately excluded. u5 has deleted their account.
insert into users(id, display_name) select t.u(n), 'u' || n from generate_series(1, 5) n;
insert into auth.users(id, email) select t.u(n), 'u' || n || '@example.com' from generate_series(1, 5) n;
update users set deleted_at = now(), display_name = 'Deleted account' where id = t.u(5);

\set OPEN 80000000-0000-0000-0000-000000000001
\set LOCKED 80000000-0000-0000-0000-000000000002
\set GHOST 80000000-0000-0000-0000-0000000000ff

insert into proposals(id, title, window_start, window_end, created_by, distribution, hidden_from)
values (:'OPEN', 'Surprise Brunch', '2026-12-01 00:00Z', '2026-12-14 00:00Z', t.u(1),
        jsonb_build_object('mode', 'newGroup', 'expectedCount', 6,
          'recipientIDs', jsonb_build_array(t.u(1), t.u(2))),
        array[t.u(4)]::uuid[]);
insert into proposals(id, title, window_start, window_end, created_by, distribution, status, locked_date, locked_end)
values (:'LOCKED', 'Settled already', '2026-11-10 00:00Z', '2026-11-24 00:00Z', t.u(1),
        jsonb_build_object('mode', 'newGroup', 'recipientIDs', jsonb_build_array(t.u(1), t.u(2))),
        'locked', '2026-11-14 18:00Z', '2026-11-14 19:30Z');

-- ===========================================================================
-- 1. F7: joining does NOT require being able to read the plan first.
--    u3 cannot read the row, and must still be able to join -- otherwise the link dead-ends.
-- ===========================================================================
select t.eq('a link holder cannot read the plan before joining',
  t.rows('select 1 from proposals where id = ' || quote_literal(:'OPEN'), t.u(3)), 0);
select t.eq('...nor through the summary view',
  t.rows('select 1 from proposal_summaries where id = ' || quote_literal(:'OPEN'), t.u(3)), 0);
select t.eq('...and yet they can join',
  (t.call('select join_proposal(' || quote_literal(:'OPEN') || ')', t.u(3))).sqlstate, '00000');
select t.eq('after joining they can read the plan',
  t.rows('select 1 from proposals where id = ' || quote_literal(:'OPEN'), t.u(3)), 1);
select t.eq('after joining they can read the summary',
  t.rows('select 1 from proposal_summaries where id = ' || quote_literal(:'OPEN'), t.u(3)), 1);
select t.eq('the join returns the title, so join-then-show is one round trip',
  t.scalar('select join_proposal(' || quote_literal(:'OPEN') || ') ->> ''title''', t.u(3)), 'Surprise Brunch');

-- Idempotent: a second tap of the same link changes nothing and is not an error.
select t.eq('a second join reports already_member',
  t.scalar('select join_proposal(' || quote_literal(:'OPEN') || ') ->> ''already_member''', t.u(3)), 'true');
select t.eq('and the recipient list has u3 exactly once',
  (select count(*)::int from jsonb_array_elements_text(
     (select distribution -> 'recipientIDs' from proposals where id = :'OPEN')) e
    where e.value = t.u(3)::text), 1);

-- ===========================================================================
-- 2. D12: the excluded id is told exactly what a stranger with a bad link is told.
--    This is the assertion the whole stealth design rests on.
-- ===========================================================================
select t.eq('an excluded id gets FC_NOT_FOUND from join_proposal',
  (t.call('select join_proposal(' || quote_literal(:'OPEN') || ')', t.u(4))).hint, 'FC_NOT_FOUND');
select t.eq('a made-up link gets FC_NOT_FOUND too',
  (t.call('select join_proposal(' || quote_literal(:'GHOST') || ')', t.u(4))).hint, 'FC_NOT_FOUND');

-- Indistinguishable means IDENTICAL, on every observable channel: sqlstate, hint and message.
select t.ok('the excluded refusal is byte-identical to the nonexistent-plan refusal',
  (select r1.sqlstate = r2.sqlstate and r1.hint is not distinct from r2.hint
          and r1.message is not distinct from r2.message
     from t.call('select join_proposal(' || quote_literal(:'OPEN') || ')', t.u(4)) r1,
          t.call('select join_proposal(' || quote_literal(:'GHOST') || ')', t.u(4)) r2));

select t.eq('the excluded id reads 0 proposal rows', t.rows('select 1 from proposals', t.u(4)), 0);
select t.eq('the excluded id reads 0 summary rows', t.rows('select 1 from proposal_summaries', t.u(4)), 0);
select t.ok('and the join attempt did not quietly add them to the recipient list',
  not ((select distribution -> 'recipientIDs' from proposals where id = :'OPEN') ? t.u(4)::text));

-- Exclusion outranks membership: even if an excluded id is somehow ALSO a recipient, they read zero.
update proposals
   set distribution = jsonb_set(distribution, '{recipientIDs}',
         (distribution -> 'recipientIDs') || to_jsonb(t.u(4)::text))
 where id = :'OPEN';
select t.eq('an excluded id who is also listed as a recipient still reads 0',
  t.rows('select 1 from proposals where id = ' || quote_literal(:'OPEN'), t.u(4)), 0);
select t.eq('...and still reads 0 through the summary view',
  t.rows('select 1 from proposal_summaries where id = ' || quote_literal(:'OPEN'), t.u(4)), 0);
select t.eq('...and join_proposal still tells them nothing',
  (t.call('select join_proposal(' || quote_literal(:'OPEN') || ')', t.u(4))).hint, 'FC_NOT_FOUND');

-- ===========================================================================
-- 3. The other refusals.
-- ===========================================================================
select t.eq('an unauthenticated caller is refused with FC_NOT_SIGNED_IN',
  (t.call('select join_proposal(' || quote_literal(:'OPEN') || ')', null)).hint, 'FC_NOT_SIGNED_IN');
select t.eq('a deleted account cannot join',
  (t.call('select join_proposal(' || quote_literal(:'OPEN') || ')', t.u(5))).hint, 'FC_ACCOUNT_DELETED');
select t.eq('a newcomer cannot join a plan that is already locked',
  (t.call('select join_proposal(' || quote_literal(:'LOCKED') || ')', t.u(3))).hint, 'FC_CLOSED');
select t.eq('but someone already party to a locked plan may still call it',
  (t.call('select join_proposal(' || quote_literal(:'LOCKED') || ')', t.u(2))).sqlstate, '00000');
select t.eq('every raise in join_proposal carries an FC_ hint',
  (select t.occurrences(prosrc, 'raise exception') from pg_proc where proname = 'join_proposal'),
  (select t.occurrences(prosrc, 'hint = ''FC_') from pg_proc where proname = 'join_proposal'));

-- ===========================================================================
-- 4. proposal_summaries: the counts mean the same thing to everyone who can read the row.
-- ===========================================================================
select t.eq('the creator reads attendee_count as max(expected, joined)',
  t.scalar('select attendee_count::text from proposal_summaries where id = ' || quote_literal(:'OPEN'), t.u(1)), '6');
select t.eq('a recipient reads the SAME attendee_count, not a number scoped to what they can see',
  t.scalar('select attendee_count::text from proposal_summaries where id = ' || quote_literal(:'OPEN'), t.u(3)), '6');
select t.eq('expected_count is null when the creator never said',
  t.scalar('select coalesce(expected_count::text, ''null'') from proposal_summaries where id = ' || quote_literal(:'LOCKED'), t.u(1)), 'null');
select t.eq('attendee_count falls back to the recipient count when expected is unstated',
  t.scalar('select attendee_count::text from proposal_summaries where id = ' || quote_literal(:'LOCKED'), t.u(1)), '2');
select t.ok('a recipient listed twice counts once',
  (select recipient_count = 2 from proposal_summaries where id = :'LOCKED'));
select t.ok('the summary view exposes no hidden_from',
  not exists (select 1 from information_schema.columns
               where table_schema = 'public' and table_name = 'proposal_summaries'
                 and column_name = 'hidden_from'));

-- ===========================================================================
-- 5. The guard still holds for clients, and still lets the RPC through.
-- ===========================================================================
-- Column privileges are checked BEFORE row policies, so withdrawing UPDATE on `distribution`
-- refuses everyone outright -- creator and stranger alike get 42501, and neither reaches the point
-- where RLS would have filtered. That ordering is worth pinning: it means the column grant, not the
-- row policy, is what protects the recipient list, and the row policy is a second line rather than
-- the first.
select t.eq('a non-creator cannot edit distribution (column grant, checked before the row policy)',
  (t.call('update proposals set distribution = ''{}''::jsonb where id = ' || quote_literal(:'OPEN'), t.u(2))).sqlstate, '42501');
select t.eq('and neither can the creator',
  (t.call('update proposals set distribution = ''{}''::jsonb where id = ' || quote_literal(:'OPEN'), t.u(1))).sqlstate, '42501');
-- The row policy is still doing its job on a column clients MAY write, so prove that path too.
select t.eq('a non-creator renaming the plan is filtered to 0 rows by the row policy',
  (t.call('update proposals set title = ''Hijacked'' where id = ' || quote_literal(:'OPEN'), t.u(2))).rows, 0);
select t.eq('while the creator may rename it',
  (t.call('update proposals set title = ''Surprise Brunch'' where id = ' || quote_literal(:'OPEN'), t.u(1))).rows, 1);
select t.ok('authenticated holds no UPDATE on proposals.distribution at all',
  not has_column_privilege('authenticated', 'proposals', 'distribution', 'UPDATE'));
select t.ok('but it may still be set at INSERT time, when the client composes the plan',
  has_column_privilege('authenticated', 'proposals', 'distribution', 'INSERT'));
select t.ok('but join_proposal moved distribution successfully, through definer context',
  ((select distribution -> 'recipientIDs' from proposals where id = :'OPEN') ? t.u(3)::text));

-- ===========================================================================
-- 5. The Swift client encodes UUIDs as UPPERCASE text; Postgres renders uuid::text in lowercase and
--    jsonb `?` is an exact match. A recipient stored the way the app stores them must still read the
--    plan, see its summary, and join idempotently -- and exclusion must still outrank membership.
--    (Found on the live project once the blanket `allow all` policies were dropped.)
--
--    Every id here is t.uh(n), not t.u(n): t.u(n) is all digits, so upper() of it is the same string
--    and the test would pass against the old case-sensitive code. (A mutation check proved it.)
-- ===========================================================================
insert into users(id, display_name) select t.uh(n), 'h' || n from generate_series(1, 5) n;
insert into auth.users(id, email) select t.uh(n), 'h' || n || '@example.com' from generate_series(1, 5) n;
select t.ok('the case fixtures really differ by case', upper(t.uh(2)::text) <> t.uh(2)::text);

-- Value: protects=a recipient stored in uppercase reads the plan and its summary, a stranger does not, and joining is idempotent; fails_when=proposal_is_readable or join_proposal goes back to a case-sensitive recipient test; why_new=every other fixture stores all-digit ids that are identical in both cases; seam=none; no_claim=mixed-case ids (unsupported by design)
\set UPPER 80000000-0000-0000-0000-000000000003
insert into proposals(id, title, window_start, window_end, created_by, distribution)
values (:'UPPER', 'Uppercase recipients', '2026-12-01 00:00Z', '2026-12-14 00:00Z', t.uh(1),
        jsonb_build_object('mode', 'newGroup',
          'recipientIDs', jsonb_build_array(upper(t.uh(1)::text), upper(t.uh(2)::text))));
select t.eq('a recipient stored in uppercase can read the plan',
  t.rows('select 1 from proposals where id = ' || quote_literal(:'UPPER'), t.uh(2)), 1);
select t.eq('...and its summary',
  t.rows('select 1 from proposal_summaries where id = ' || quote_literal(:'UPPER'), t.uh(2)), 1);
select t.eq('a stranger still reads nothing',
  t.rows('select 1 from proposals where id = ' || quote_literal(:'UPPER'), t.uh(3)), 0);
select t.eq('joining as an uppercase-stored recipient reports already_member, not a second entry',
  t.scalar('select join_proposal(' || quote_literal(:'UPPER') || ') ->> ''already_member''', t.uh(2)), 'true');
select t.eq('and the recipient list still has exactly two entries',
  (select jsonb_array_length(distribution -> 'recipientIDs') from proposals where id = :'UPPER'), 2);
select t.eq('the summary counts them once',
  t.scalar('select recipient_count::text from proposal_summaries where id = ' || quote_literal(:'UPPER'), t.uh(1)), '2');

-- Value: protects=the users read policy admits a co-participant stored in uppercase through its recipient branch; fails_when=the policy reverts to a case-sensitive recipient test; why_new=reading the host passes through created_by and never reaches that branch; seam=none; no_claim=none beyond protects
\set UPPER2 80000000-0000-0000-0000-000000000004
insert into proposals(id, title, window_start, window_end, created_by, distribution)
values (:'UPPER2', 'Uppercase pair', '2026-12-01 00:00Z', '2026-12-14 00:00Z', t.uh(1),
        jsonb_build_object('mode', 'newGroup',
          'recipientIDs', jsonb_build_array(upper(t.uh(2)::text), upper(t.uh(4)::text))));
select t.eq('a recipient stored in uppercase reads another uppercase recipient (not the host)',
  t.rows('select 1 from users where id = ' || quote_literal(t.uh(4)), t.uh(2)), 1);
select t.eq('a user who is on no plan cannot read them',
  t.rows('select 1 from users where id = ' || quote_literal(t.uh(4)), t.uh(5)), 0);

-- Value: protects=a person listed in both spellings counts once in the summary; fails_when=count(distinct lower(...)) reverts to count(distinct ...); why_new=no other fixture lists one person twice; seam=none; no_claim=none beyond protects
\set MIXED 80000000-0000-0000-0000-000000000005
insert into proposals(id, title, window_start, window_end, created_by, distribution)
values (:'MIXED', 'Both spellings', '2026-12-01 00:00Z', '2026-12-14 00:00Z', t.uh(1),
        jsonb_build_object('mode', 'newGroup', 'expectedCount', 1,
          'recipientIDs', jsonb_build_array(t.uh(2), upper(t.uh(2)::text), upper(t.uh(3)::text))));
select t.eq('one person in both spellings is counted once (recipient_count)',
  t.scalar('select recipient_count::text from proposal_summaries where id = ' || quote_literal(:'MIXED'), t.uh(1)), '2');
select t.eq('...and attendee_count is the larger of that and expectedCount',
  t.scalar('select attendee_count::text from proposal_summaries where id = ' || quote_literal(:'MIXED'), t.uh(1)), '2');

-- Value: protects=friendcal_has_recipient contract for each spelling, a non-member, a NULL uid and a missing list; fails_when=either spelling arm, the NULL-uid guard or the coalesce is removed; why_new=other assertions reach it only through policies; seam=none; no_claim=none beyond protects
select t.eq('helper: lowercase spelling matches',
  friendcal_has_recipient(jsonb_build_object('recipientIDs', jsonb_build_array(t.uh(2)::text)), t.uh(2)), true);
select t.eq('helper: uppercase spelling matches',
  friendcal_has_recipient(jsonb_build_object('recipientIDs', jsonb_build_array(upper(t.uh(2)::text))), t.uh(2)), true);
select t.eq('helper: a non-member does not match',
  friendcal_has_recipient(jsonb_build_object('recipientIDs', jsonb_build_array(t.uh(2)::text)), t.uh(3)), false);
select t.eq('helper: a NULL uid is false, not NULL',
  friendcal_has_recipient(jsonb_build_object('recipientIDs', jsonb_build_array(t.uh(2)::text)), null), false);
select t.eq('helper: false, never NULL, when distribution has no recipientIDs',
  friendcal_has_recipient('{}'::jsonb, t.uh(2)), false);
select t.eq('helper: nor when the distribution itself is NULL',
  friendcal_has_recipient(null, t.uh(2)), false);

update proposals set hidden_from = array[t.uh(2)]::uuid[] where id = :'UPPER';
select t.eq('exclusion outranks an uppercase-stored membership',
  t.rows('select 1 from proposals where id = ' || quote_literal(:'UPPER'), t.uh(2)), 0);

\echo 'join_proposal tests: all passed'
