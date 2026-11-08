-- Place voting (#10, #11): reads, writes, the error contract, the winner rule, caps, dedupe, votes,
-- veto, withdraw, closed plans, the host's city, helper privileges and account deletion.
-- Run with scripts/test-sql.sh, which loads the wave and tests/helpers.sql first and exports
-- FC_FIXTURES (the directory holding place_winner_cases.json). t.ok, t.eq, t.u, t.rows, t.call and
-- t.scalar come from helpers.sql.
--
-- Every read and refusal goes through a t.* helper, which runs under `set local role`. A bare
-- `select count(*)` here would run as a superuser and pass against a deny-all policy.
--
-- Cards. Each section says what it protects, what wrong result it rejects, and what green does not
-- prove: protects=<observable>; fails_when=<wrong result>; no_claim=<what is not shown>.
\set ON_ERROR_STOP 1
set client_min_messages = notice;
\set cases `cat "$FC_FIXTURES/place_winner_cases.json"`

-- u1 hosts. u2 to u5 are members. u6 is a member who is EXCLUDED from the surprise plan. u7 is a
-- member who has deleted their account. u8 is not on any plan. u8 and u9 are the deletion subjects
-- in section 13, so nothing before it may rely on them staying active.
insert into users(id, display_name) select t.u(n), 'u' || n from generate_series(1, 9) n;
insert into auth.users(id, email) select t.u(n), 'u' || n || '@example.com' from generate_series(1, 9) n;
update users set deleted_at = now(), display_name = 'Deleted account' where id = t.u(7);

-- ---------------------------------------------------------------------------
-- Fixtures and wrappers. Wrappers build the statement with format(%L) and run it through t.call, so
-- a refusal is reported as (sqlstate, hint, message) instead of aborting the file.
-- ---------------------------------------------------------------------------
create function t.pid(n int) returns uuid language sql immutable as $$
  select ('e0000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function t.plid(n int) returns uuid language sql immutable as $$
  select ('f0000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;

-- A plan hosted by `creator` with u1..u7 as recipients, a city unless told otherwise.
create function t.mkplan(pid uuid, st text default 'requesting', has_area boolean default true,
                         hidden uuid[] default '{}', creator uuid default t.u(1)) returns uuid
language plpgsql as $$
begin
  insert into proposals(id, title, window_start, window_end, created_by, distribution, status, hidden_from,
                        area_name, area_lat, area_lon, locked_date, locked_end)
  values (pid, 'Brunch', '2026-12-01 00:00Z', '2026-12-14 00:00Z', creator,
          jsonb_build_object('mode', 'newGroup', 'recipientIDs', jsonb_build_array(
            creator, t.u(2), t.u(3), t.u(4), t.u(5), t.u(6), t.u(7))),
          st, hidden,
          case when has_area then 'Austin, TX' end, case when has_area then 30.2672 end,
          case when has_area then -97.7431 end,
          case when st = 'locked' then '2026-12-05 18:00Z'::timestamptz end,
          case when st = 'locked' then '2026-12-05 19:30Z'::timestamptz end);
  return pid;
end $$;

-- Direct fixture inserts, as the superuser the harness is. These bypass every rule on purpose.
create function t.place(plid uuid, pid uuid, by uuid, nm text, lat double precision default 30.2672,
                        lon double precision default -97.7431, at timestamptz default now(),
                        vetoed boolean default false, ref text default null) returns uuid
language sql as $$
  insert into proposal_places(id, proposal_id, suggested_by, name, lat, lon, map_ref, created_at, vetoed_at)
  values (plid, pid, by, nm, lat, lon, ref, at, case when vetoed then at end)
  returning id $$;
create function t.cast(pid uuid, voter uuid, plid uuid) returns void language sql as $$
  insert into place_votes(proposal_id, voter_id, place_id) values (pid, voter, plid) $$;

-- Client calls.
create function t.suggest(pid uuid, uid uuid, nm text, lat text default '30.2672', lon text default '-97.7431',
                          ref text default null, addr text default null) returns t.outcome language sql as $$
  select t.call(format('select suggest_place(%L, %L, %L, %L, %L, %L)', pid, nm, addr, lat, lon, ref), uid) $$;
create function t.suggest_id(pid uuid, uid uuid, nm text, lat text default '30.2672', lon text default '-97.7431',
                             ref text default null) returns uuid language sql as $$
  select t.scalar(format('select (suggest_place(%L, %L, null, %L, %L, %L)).id', pid, nm, lat, lon, ref), uid)::uuid $$;
create function t.vote(pid uuid, plid uuid, uid uuid) returns t.outcome language sql as $$
  select t.call(format('select vote_place(%L, %L)', pid, plid), uid) $$;
create function t.veto(plid uuid, v boolean, uid uuid) returns t.outcome language sql as $$
  select t.call(format('select veto_place(%L, %L)', plid, v), uid) $$;
create function t.remove(plid uuid, uid uuid) returns t.outcome language sql as $$
  select t.call(format('select remove_place(%L)', plid), uid) $$;

-- Assertions on an outcome: the SQLSTATE and the hint are the wire contract.
create function t.refuses(nm text, o t.outcome, state text, h text) returns void language plpgsql as $$
begin
  if o.sqlstate is distinct from state or coalesce(o.hint, '') <> coalesce(h, '') then
    raise exception 'not ok - %: got % / %, want % / % (%)', nm, o.sqlstate, coalesce(o.hint, 'NULL'),
      state, coalesce(h, 'NULL'), coalesce(o.message, '');
  end if;
  raise notice 'ok - % (% %)', nm, state, coalesce(h, '');
end $$;
create function t.succeeds(nm text, o t.outcome) returns void language plpgsql as $$
begin
  if o.sqlstate <> '00000' then
    raise exception 'not ok - %: refused % / % (%)', nm, o.sqlstate, coalesce(o.hint, 'NULL'), coalesce(o.message, '');
  end if;
  raise notice 'ok - %', nm;
end $$;
-- Two outcomes that must be indistinguishable: same SQLSTATE, same hint, same message.
create function t.same(nm text, a t.outcome, b t.outcome) returns void language plpgsql as $$
begin
  if a.sqlstate is distinct from b.sqlstate or a.hint is distinct from b.hint or a.message is distinct from b.message then
    raise exception 'not ok - %: (% / % / %) differs from (% / % / %)', nm,
      a.sqlstate, a.hint, a.message, b.sqlstate, b.hint, b.message;
  end if;
  raise notice 'ok - % (% % "%")', nm, a.sqlstate, a.hint, a.message;
end $$;
create function t.nth_place(pid uuid, by uuid, n int) returns uuid language sql as $$
  select id from proposal_places where proposal_id = pid and suggested_by = by order by created_at, id offset n - 1 limit 1 $$;
grant execute on all functions in schema t to anon, authenticated, service_role;

-- ===========================================================================
-- 1. T1 read scope. protects=a member sees the plan's places and votes and nobody else does;
--    fails_when=the select policy is using(true) or ignores hidden_from;
--    no_claim=Realtime delivery, which is not set up; fixture rows are inserted as superuser.
-- ===========================================================================
select t.mkplan(t.pid(1), hidden => array[t.u(6)]);
select t.place(t.plid(1), t.pid(1), t.u(2), 'Cafe Lola');
select t.place(t.plid(2), t.pid(1), t.u(3), 'Juniper Table');
select t.cast(t.pid(1), t.u(4), t.plid(1));

select t.eq('the host reads both places', t.rows('select 1 from proposal_places where proposal_id = ' || quote_literal(t.pid(1)), t.u(1)), 2);
select t.eq('a member reads both places', t.rows('select 1 from proposal_places where proposal_id = ' || quote_literal(t.pid(1)), t.u(5)), 2);
select t.eq('a member reads the votes', t.rows('select 1 from place_votes where proposal_id = ' || quote_literal(t.pid(1)), t.u(5)), 1);
select t.eq('a non-member reads no places', t.rows('select 1 from proposal_places where proposal_id = ' || quote_literal(t.pid(1)), t.u(8)), 0);
select t.eq('a non-member reads no votes', t.rows('select 1 from place_votes where proposal_id = ' || quote_literal(t.pid(1)), t.u(8)), 0);
select t.eq('an excluded member reads no places', t.rows('select 1 from proposal_places where proposal_id = ' || quote_literal(t.pid(1)), t.u(6)), 0);
select t.eq('an excluded member reads no votes', t.rows('select 1 from place_votes where proposal_id = ' || quote_literal(t.pid(1)), t.u(6)), 0);
select t.refuses('anon is refused on places', t.call('select 1 from proposal_places', null, 'anon'), '42501', null);
select t.refuses('anon is refused on votes', t.call('select 1 from place_votes', null, 'anon'), '42501', null);

-- ===========================================================================
-- 2. T2 no direct writes. protects=every write must use the functions;
--    fails_when=any insert, update or delete grant on either table survives;
--    no_claim=Supabase's own default privileges beyond what the stubs mirror.
-- ===========================================================================
select t.refuses('a member cannot insert a place directly',
  t.call(format('insert into proposal_places(proposal_id, suggested_by, name, lat, lon) values (%L, %L, ''x'', 1, 1)', t.pid(1), t.u(2)), t.u(2)),
  '42501', null);
select t.refuses('a member cannot update a place directly',
  t.call(format('update proposal_places set name = ''x'' where id = %L', t.plid(1)), t.u(2)), '42501', null);
select t.refuses('a member cannot delete a place directly',
  t.call(format('delete from proposal_places where id = %L', t.plid(1)), t.u(2)), '42501', null);
select t.refuses('a member cannot insert a vote directly',
  t.call(format('insert into place_votes(proposal_id, voter_id, place_id) values (%L, %L, %L)', t.pid(1), t.u(5), t.plid(2)), t.u(5)),
  '42501', null);
select t.refuses('a member cannot update a vote directly',
  t.call(format('update place_votes set place_id = %L where voter_id = %L', t.plid(2), t.u(4)), t.u(4)), '42501', null);
select t.refuses('a member cannot delete a vote directly',
  t.call(format('delete from place_votes where voter_id = %L', t.u(4)), t.u(4)), '42501', null);

-- ===========================================================================
-- 3. T3 the winner column is server-owned. protects=the host cannot set the winner by hand, by
--    privilege and by the guard behind it; fails_when=locked_place_id appears in an insert or update
--    grant, or is missing from the guard or the insert policy; no_claim=nothing about other columns.
-- ===========================================================================
select t.refuses('a direct update of locked_place_id fails on the column privilege',
  t.call(format('update proposals set locked_place_id = %L where id = %L', t.plid(1), t.pid(1)), t.u(1)), '42501', null);
select t.refuses('an insert carrying locked_place_id fails on the column privilege',
  t.call(format('insert into proposals(id, title, window_start, window_end, created_by, locked_place_id) values (%L, ''x'', now(), now() + interval ''1 day'', %L, %L)',
                gen_random_uuid(), t.u(1), t.plid(1)), t.u(1)), '42501', null);
select t.ok('the winner column is selectable by a member', t.can_select('proposals', 'locked_place_id'));
select t.ok('the winner column is not insertable or updatable',
  not has_column_privilege('authenticated', 'proposals', 'locked_place_id', 'INSERT')
  and not has_column_privilege('authenticated', 'proposals', 'locked_place_id', 'UPDATE'));
-- Defense in depth, proven by temporarily granting the column inside a transaction that is rolled back.
begin;
grant update (locked_place_id) on proposals to authenticated;
grant insert (locked_place_id) on proposals to authenticated;
select t.refuses('the edit guard rejects the winner when the privilege is granted',
  t.call(format('update proposals set locked_place_id = %L where id = %L', t.plid(1), t.pid(1)), t.u(1)),
  '42501', 'FC_SERVER_OWNED_FIELD');
select t.ok('the insert policy rejects the winner when the privilege is granted',
  (select (x.o).sqlstate = '42501' and (x.o).message like 'new row violates row-level security%'
     from (select t.call(format('insert into proposals(id, title, window_start, window_end, created_by, locked_place_id) values (%L, ''x'', now(), now() + interval ''1 day'', %L, %L)',
                                gen_random_uuid(), t.u(1), t.plid(1)), t.u(1)) as o) x));
rollback;

-- ===========================================================================
-- 4. T4 error contract, part one: the guard. protects=each refusal carries the exact SQLSTATE and
--    hint the client maps; fails_when=a hint is missing, misspelled or on the wrong code;
--    no_claim=client copy. The remaining rows are asserted where they arise: FC_LOCKED and FC_CLOSED
--    in section 10, the caps in 6, FC_VETOED and FC_OWN_PLACE in 7 and 8, FC_NOT_CREATOR in 9,
--    FC_NOT_YOUR_PLACE in 10, the city rules in 12.
-- ===========================================================================
select t.mkplan(t.pid(2), has_area => false);
select t.refuses('not signed in', t.suggest(t.pid(1), null, 'X'), '42501', 'FC_NOT_SIGNED_IN');
select t.refuses('not signed in (vote)', t.vote(t.pid(1), t.plid(1), null), '42501', 'FC_NOT_SIGNED_IN');
select t.refuses('not signed in (veto)', t.veto(t.plid(1), true, null), '42501', 'FC_NOT_SIGNED_IN');
select t.refuses('not signed in (remove)', t.remove(t.plid(1), null), '42501', 'FC_NOT_SIGNED_IN');
select t.refuses('anon cannot call suggest_place', t.call(format('select suggest_place(%L, ''X'', null, 1, 1, null)', t.pid(1)), null, 'anon'), '42501', null);
select t.refuses('an unknown plan', t.suggest(t.pid(99), t.u(2), 'X'), 'P0002', 'FC_NOT_FOUND');
select t.refuses('a null plan id', t.suggest(null, t.u(2), 'X'), 'P0002', 'FC_NOT_FOUND');
select t.refuses('a deleted account', t.suggest(t.pid(2), t.u(7), 'X'), '42501', 'FC_ACCOUNT_DELETED');
select t.refuses('a non-member who is not excluded gets NOT_MEMBER, not NOT_FOUND', t.suggest(t.pid(2), t.u(8), 'X'), '42501', 'FC_NOT_MEMBER');
select t.refuses('a plan with no city', t.suggest(t.pid(2), t.u(2), 'X'), 'P0001', 'FC_NO_AREA');
select t.refuses('a vote on a plan with no city finds no such place',
  t.vote(t.pid(2), t.plid(1), t.u(2)), 'P0002', 'FC_PLACE_NOT_FOUND');

-- Invalid fields: every branch is FC_BAD_PLACE under 22023.
select t.refuses('a blank name', t.suggest(t.pid(1), t.u(2), '   '), '22023', 'FC_BAD_PLACE');
select t.refuses('a null name', t.suggest(t.pid(1), t.u(2), null), '22023', 'FC_BAD_PLACE');
select t.refuses('a 121-character name', t.suggest(t.pid(1), t.u(2), repeat('n', 121)), '22023', 'FC_BAD_PLACE');
select t.refuses('a 241-character address', t.suggest(t.pid(1), t.u(2), 'Valid', addr => repeat('a', 241)), '22023', 'FC_BAD_PLACE');
select t.refuses('a 201-character map reference', t.suggest(t.pid(1), t.u(2), 'Valid', ref => repeat('m', 201)), '22023', 'FC_BAD_PLACE');
select t.refuses('latitude above 90', t.suggest(t.pid(1), t.u(2), 'Valid', lat => '90.5'), '22023', 'FC_BAD_PLACE');
select t.refuses('longitude below -180', t.suggest(t.pid(1), t.u(2), 'Valid', lon => '-180.5'), '22023', 'FC_BAD_PLACE');
select t.refuses('a null latitude', t.suggest(t.pid(1), t.u(2), 'Valid', lat => null), '22023', 'FC_BAD_PLACE');
select t.refuses('a NaN longitude', t.suggest(t.pid(1), t.u(2), 'Valid', lon => 'NaN'), '22023', 'FC_BAD_PLACE');
select t.succeeds('a 120-character name is accepted', t.suggest(t.pid(1), t.u(5), repeat('n', 120), '31.0', '-97.0'));
select t.succeeds('a padded name with a blank address is accepted', t.suggest(t.pid(1), t.u(2), '  Trim Me  ', '31.1', '-97.1', addr => '   '));
select t.eq('the name is stored trimmed and a blank address becomes null',
  (select name || '|' || coalesce(address, 'NULL') from proposal_places where proposal_id = t.pid(1) and suggested_by = t.u(2) and name like 'Trim%'),
  'Trim Me|NULL');

-- ===========================================================================
-- 5. T5 excluded equals missing. protects=an excluded caller cannot tell the plan exists;
--    fails_when=any function raises a different code, hint or message for an excluded caller;
--    no_claim=timing differences between the two paths.
-- ===========================================================================
select t.refuses('an excluded caller gets NOT_FOUND from suggest_place', t.suggest(t.pid(1), t.u(6), 'X'), 'P0002', 'FC_NOT_FOUND');
select t.same('suggest_place: excluded equals missing', t.suggest(t.pid(1), t.u(6), 'X'), t.suggest(t.pid(99), t.u(2), 'X'));
select t.same('vote_place: excluded equals missing', t.vote(t.pid(1), t.plid(1), t.u(6)), t.vote(t.pid(99), t.plid(1), t.u(2)));
select t.same('vote_place clear: excluded equals missing', t.vote(t.pid(1), null, t.u(6)), t.vote(t.pid(99), null, t.u(2)));
select t.same('veto_place: excluded equals an unknown place', t.veto(t.plid(1), true, t.u(6)), t.veto(t.plid(99), true, t.u(1)));
select t.same('remove_place: excluded equals an unknown place', t.remove(t.plid(1), t.u(6)), t.remove(t.plid(99), t.u(2)));
select t.refuses('veto of an unknown place is NOT_FOUND for a member too', t.veto(t.plid(99), true, t.u(1)), 'P0002', 'FC_NOT_FOUND');
select t.refuses('remove of an unknown place is NOT_FOUND for a member too', t.remove(t.plid(99), t.u(2)), 'P0002', 'FC_NOT_FOUND');
select t.ok('the excluded caller left no trace',
  (select count(*) = 0 from proposal_places where suggested_by = t.u(6)) and (select count(*) = 1 from place_votes where proposal_id = t.pid(1)));

-- ===========================================================================
-- 6. T6 caps. protects=three suggestions by one person and eleven places on a plan are refused, and
--    vetoed or withdrawn places do not count; fails_when=a cap counts vetoed rows or does not count
--    at all; no_claim=the numbers 2 and 10 as product choices.
-- ===========================================================================
select t.mkplan(t.pid(6));
select t.eq('five friends each add two places',
  (select count(*)::int from generate_series(1, 5) n, generate_series(1, 2) k
    where (t.suggest(t.pid(6), t.u(n), format('Spot %s-%s', n, k), (30.0 + n * 0.1 + k * 0.01)::text, '-97.7')).sqlstate = '00000'), 10);
select t.refuses('a third active suggestion by one person is refused', t.suggest(t.pid(6), t.u(2), 'Spot 2-3', '31.5', '-97.7'), '54000', 'FC_PLACE_LIMIT');
select t.refuses('the eleventh place is refused', t.suggest(t.pid(6), t.u(6), 'Spot 6-1', '31.6', '-97.7'), '54000', 'FC_PLAN_FULL');
select t.refuses('the personal cap is reported before the plan cap', t.suggest(t.pid(6), t.u(3), 'Spot 3-3', '31.7', '-97.7'), '54000', 'FC_PLACE_LIMIT');
select t.succeeds('the host passes on one of u2''s places', t.veto(t.nth_place(t.pid(6), t.u(2), 1), true, t.u(1)));
select t.succeeds('a vetoed place does not count: u2 can suggest again', t.suggest(t.pid(6), t.u(2), 'Spot 2-new', '31.8', '-97.7'));
select t.succeeds('u3 withdraws a place', t.remove(t.nth_place(t.pid(6), t.u(3), 1), t.u(3)));
select t.succeeds('a withdrawn place does not count: u3 can suggest again', t.suggest(t.pid(6), t.u(3), 'Spot 3-new', '31.9', '-97.7'));
select t.eq('the plan is full again at ten active places',
  (select count(*)::int from proposal_places where proposal_id = t.pid(6) and vetoed_at is null), 10);

-- ===========================================================================
-- 7. T7 dedupe. protects=a repeat suggestion returns the existing active row, a vetoed-only repeat is
--    refused, and an active match beats a vetoed one; fails_when=a duplicate row is created, or a
--    veto can be bypassed by re-suggesting; no_claim=matching places more than 110 m apart or spelled
--    differently.
-- ===========================================================================
select t.mkplan(t.pid(7));
select t.eq('a first suggestion creates a row', (select count(*)::int from (select t.suggest_id(t.pid(7), t.u(2), 'Cafe Lola', '30.2672', '-97.7431', 'M1')) x), 1);
select t.eq('the same map reference returns the existing row, whatever the name',
  t.suggest_id(t.pid(7), t.u(3), 'Something else entirely', '40.0', '-100.0', 'M1'), t.nth_place(t.pid(7), t.u(2), 1));
select t.eq('the same name in another case within 0.0005 degrees returns the existing row',
  t.suggest_id(t.pid(7), t.u(4), 'CAFE LOLA', '30.2677', '-97.7436'), t.nth_place(t.pid(7), t.u(2), 1));
select t.eq('so far there is one row', (select count(*)::int from proposal_places where proposal_id = t.pid(7)), 1);
select t.succeeds('the same name 0.002 degrees away is a different place', t.suggest(t.pid(7), t.u(4), 'Cafe Lola', '30.2692', '-97.7431'));
select t.eq('so now there are two', (select count(*)::int from proposal_places where proposal_id = t.pid(7)), 2);
select t.succeeds('the host passes on the first Cafe Lola', t.veto(t.nth_place(t.pid(7), t.u(2), 1), true, t.u(1)));
select t.refuses('re-suggesting a vetoed place by map reference is refused', t.suggest(t.pid(7), t.u(3), 'Another name', '10.0', '10.0', 'M1'), 'P0001', 'FC_VETOED');
select t.refuses('re-suggesting a vetoed place by name and position is refused', t.suggest(t.pid(7), t.u(5), 'cafe lola', '30.2672', '-97.7431'), 'P0001', 'FC_VETOED');
select t.mkplan(t.pid(8));
select t.place(t.plid(81), t.pid(8), t.u(2), 'Dup Place', at => '2026-11-10 10:00Z', vetoed => true);
select t.place(t.plid(82), t.pid(8), t.u(3), 'Dup Place', at => '2026-11-10 10:05Z');
select t.eq('an active match beats a vetoed one', t.suggest_id(t.pid(8), t.u(4), 'Dup Place'), t.plid(82));
-- The boundary: strictly less than 0.001 degrees. 0.0 against 0.001 is the literal itself, so
-- floating-point subtraction cannot blur it.
select t.mkplan(t.pid(9));
select t.place(t.plid(91), t.pid(9), t.u(2), 'Edge', 0.0, 0.0);
select t.eq('0.0009 degrees apart is the same place', t.suggest_id(t.pid(9), t.u(3), 'Edge', '0.0009', '0.0'), t.plid(91));
select t.succeeds('exactly 0.001 apart is a new place', t.suggest(t.pid(9), t.u(3), 'Edge', '0.001', '0.0'));
select t.succeeds('exactly 0.001 apart on longitude is a new place', t.suggest(t.pid(9), t.u(4), 'Edge', '0.0', '0.001'));
select t.eq('so there are three Edge places', (select count(*)::int from proposal_places where proposal_id = t.pid(9)), 3);

-- ===========================================================================
-- 8. T8 vote rules. protects=one vote per person, own place refused, move and clear work, and a
--    repeated vote keeps its timestamp; fails_when=two vote rows for one person, a self-vote is
--    accepted, or a repeated vote changes created_at; no_claim=whether the UI offers a self-vote.
-- ===========================================================================
select t.mkplan(t.pid(10));
select t.place(t.plid(101), t.pid(10), t.u(2), 'A place');
select t.place(t.plid(102), t.pid(10), t.u(3), 'B place');
select t.place(t.plid(103), t.pid(10), t.u(3), 'Vetoed place', vetoed => true);
select t.succeeds('u4 votes for A', t.vote(t.pid(10), t.plid(101), t.u(4)));
select t.eq('one vote row for u4', (select count(*)::int from place_votes where proposal_id = t.pid(10) and voter_id = t.u(4)), 1);
create temp table t_vote_time as select created_at from place_votes where voter_id = t.u(4) and proposal_id = t.pid(10);
select t.succeeds('u4 votes for A again', t.vote(t.pid(10), t.plid(101), t.u(4)));
select t.ok('a repeated vote keeps its created_at',
  (select v.created_at = (select created_at from t_vote_time) from place_votes v where v.voter_id = t.u(4) and v.proposal_id = t.pid(10)));
select t.succeeds('u4 moves the vote to B', t.vote(t.pid(10), t.plid(102), t.u(4)));
select t.eq('still exactly one vote row for u4', (select count(*)::int from place_votes where proposal_id = t.pid(10) and voter_id = t.u(4)), 1);
select t.eq('and it points at B', (select place_id from place_votes where proposal_id = t.pid(10) and voter_id = t.u(4)), t.plid(102));
select t.ok('a moved vote gets a later created_at',
  (select v.created_at > (select created_at from t_vote_time) from place_votes v where v.voter_id = t.u(4) and v.proposal_id = t.pid(10)));
select t.refuses('a vote for your own suggestion is refused', t.vote(t.pid(10), t.plid(101), t.u(2)), '42501', 'FC_OWN_PLACE');
select t.refuses('a vote for a vetoed place is refused', t.vote(t.pid(10), t.plid(103), t.u(4)), 'P0001', 'FC_VETOED');
select t.refuses('a vote for a place on another plan is refused', t.vote(t.pid(10), t.plid(1), t.u(4)), 'P0002', 'FC_PLACE_NOT_FOUND');
select t.refuses('a vote for an unknown place is refused', t.vote(t.pid(10), t.plid(98), t.u(4)), 'P0002', 'FC_PLACE_NOT_FOUND');
select t.refuses('a non-member cannot vote', t.vote(t.pid(10), t.plid(101), t.u(8)), '42501', 'FC_NOT_MEMBER');
select t.succeeds('clearing the vote works', t.vote(t.pid(10), null, t.u(4)));
select t.eq('and leaves no row', (select count(*)::int from place_votes where proposal_id = t.pid(10) and voter_id = t.u(4)), 0);
select t.succeeds('clearing with no vote is a no-op', t.vote(t.pid(10), null, t.u(4)));

-- ===========================================================================
-- 9. T9 veto cycle. protects=a veto deletes the votes on that place, bringing it back restores it
--    with zero votes, a non-host cannot veto, and bringing back respects the caps; fails_when=a veto
--    leaves orphan votes or a non-host vetoes; no_claim=vote history after a veto, which is
--    deliberately not kept.
-- ===========================================================================
select t.mkplan(t.pid(11));
select t.place(t.plid(111), t.pid(11), t.u(2), 'Veto me');
select t.place(t.plid(112), t.pid(11), t.u(3), 'Keep me');
select t.cast(t.pid(11), t.u(4), t.plid(111));
select t.cast(t.pid(11), t.u(5), t.plid(111));
select t.cast(t.pid(11), t.u(6), t.plid(112));
select t.refuses('a non-host cannot veto', t.veto(t.plid(111), true, t.u(2)), '42501', 'FC_NOT_CREATOR');
select t.refuses('a non-host cannot bring a place back either', t.veto(t.plid(111), false, t.u(3)), '42501', 'FC_NOT_CREATOR');
select t.refuses('a non-host with a null flag still gets NOT_CREATOR first', t.veto(t.plid(111), null, t.u(2)), '42501', 'FC_NOT_CREATOR');
select t.refuses('a null flag from the host is a bad place', t.veto(t.plid(111), null, t.u(1)), '22023', 'FC_BAD_PLACE');
select t.succeeds('the host vetoes', t.veto(t.plid(111), true, t.u(1)));
select t.ok('the place is marked vetoed', (select vetoed_at is not null from proposal_places where id = t.plid(111)));
select t.eq('its votes are gone', (select count(*)::int from place_votes where place_id = t.plid(111)), 0);
select t.eq('other places keep their votes', (select count(*)::int from place_votes where place_id = t.plid(112)), 1);
create temp table t_veto_time as select vetoed_at from proposal_places where id = t.plid(111);
select t.succeeds('a second veto is a no-op', t.veto(t.plid(111), true, t.u(1)));
select t.ok('...and does not restamp the veto', (select vetoed_at = (select vetoed_at from t_veto_time) from proposal_places where id = t.plid(111)));
select t.succeeds('the host brings it back', t.veto(t.plid(111), false, t.u(1)));
select t.ok('it is active again', (select vetoed_at is null from proposal_places where id = t.plid(111)));
select t.eq('with zero votes', (select count(*)::int from place_votes where place_id = t.plid(111)), 0);
select t.succeeds('bringing back an active place is a no-op', t.veto(t.plid(111), false, t.u(1)));
-- Bring back under the personal cap: u2 has Veto me (vetoed) plus two newer active places.
select t.succeeds('u2 adds a second active place', t.suggest(t.pid(11), t.u(2), 'u2 second', '31.1', '-97.7'));
select t.succeeds('the host vetoes Veto me again', t.veto(t.plid(111), true, t.u(1)));
select t.succeeds('u2 adds a third place while one is vetoed', t.suggest(t.pid(11), t.u(2), 'u2 third', '31.2', '-97.7'));
select t.refuses('bringing back over the personal cap is refused', t.veto(t.plid(111), false, t.u(1)), '54000', 'FC_PLACE_LIMIT');
-- Bring back over the plan cap: ten active places by people who are each under their personal cap.
select t.mkplan(t.pid(12));
select t.place(t.plid(120 + n), t.pid(12), t.u(2 + (n % 4)), 'Full ' || n, 30.0 + n, -97.7) from generate_series(1, 10) n;
select t.place(t.plid(131), t.pid(12), t.u(6), 'Passed', vetoed => true);
select t.refuses('bringing back onto a full plan is refused', t.veto(t.plid(131), false, t.u(1)), '54000', 'FC_PLAN_FULL');

-- ===========================================================================
-- 10. T10 withdraw, T11 closed plans. protects=only the suggester removes a place and its votes go
--     with it; locked and cancelled plans refuse all four functions; fails_when=the host or a friend
--     removes someone else's place, or any function succeeds after lock; no_claim=soft-delete
--     semantics, which are not provided, and plans in states the fixtures do not produce.
-- ===========================================================================
select t.mkplan(t.pid(13));
select t.place(t.plid(141), t.pid(13), t.u(2), 'Withdraw me');
select t.cast(t.pid(13), t.u(3), t.plid(141));
select t.cast(t.pid(13), t.u(4), t.plid(141));
select t.refuses('a friend cannot remove someone else''s place', t.remove(t.plid(141), t.u(3)), '42501', 'FC_NOT_YOUR_PLACE');
select t.refuses('the host cannot remove someone else''s place', t.remove(t.plid(141), t.u(1)), '42501', 'FC_NOT_YOUR_PLACE');
select t.succeeds('the suggester withdraws', t.remove(t.plid(141), t.u(2)));
select t.eq('the place is gone', (select count(*)::int from proposal_places where id = t.plid(141)), 0);
select t.eq('and so are its votes', (select count(*)::int from place_votes where proposal_id = t.pid(13)), 0);

select t.mkplan(t.pid(14), 'locked');
select t.mkplan(t.pid(15), 'cancelled');
select t.place(t.plid(151), t.pid(14), t.u(2), 'On a locked plan');
select t.place(t.plid(152), t.pid(15), t.u(2), 'On a cancelled plan');
select t.refuses('suggest on a locked plan', t.suggest(t.pid(14), t.u(3), 'X'), '55000', 'FC_LOCKED');
select t.refuses('vote on a locked plan', t.vote(t.pid(14), t.plid(151), t.u(3)), '55000', 'FC_LOCKED');
select t.refuses('veto on a locked plan', t.veto(t.plid(151), true, t.u(1)), '55000', 'FC_LOCKED');
select t.refuses('remove on a locked plan', t.remove(t.plid(151), t.u(2)), '55000', 'FC_LOCKED');
select t.refuses('suggest on a cancelled plan', t.suggest(t.pid(15), t.u(3), 'X'), '55000', 'FC_CLOSED');
select t.refuses('vote on a cancelled plan', t.vote(t.pid(15), t.plid(152), t.u(3)), '55000', 'FC_CLOSED');
select t.refuses('veto on a cancelled plan', t.veto(t.plid(152), true, t.u(1)), '55000', 'FC_CLOSED');
select t.refuses('remove on a cancelled plan', t.remove(t.plid(152), t.u(2)), '55000', 'FC_CLOSED');

-- ===========================================================================
-- 11. T12 winner cases. protects=the function returns the expected winner for P1 to P6, read from the
--     one shared file the Swift tests also read; fails_when=any case differs, or id ties compare
--     differently from Postgres; no_claim=the Swift copy of the rule, which reads the same file.
--     The lock side (a lock stores this function's result) is asserted in lock_proposal_test.sql.
-- ===========================================================================
create table t.winner_cases as
  select ord::int as i, c ->> 'name' as nm, c as j
    from jsonb_array_elements(:'cases'::jsonb -> 'cases') with ordinality as x(c, ord);
insert into proposals(id, title, window_start, window_end, created_by, distribution, area_name, area_lat, area_lon)
select ('d0000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid, nm, '2026-12-01 00:00Z', '2026-12-14 00:00Z', t.u(1),
       jsonb_build_object('mode', 'newGroup', 'recipientIDs', jsonb_build_array(t.u(1))), 'Austin, TX', 30.2672, -97.7431
  from t.winner_cases;
insert into proposal_places(id, proposal_id, suggested_by, name, lat, lon, created_at, vetoed_at)
select (p ->> 'id')::uuid, ('d0000000-0000-0000-0000-' || lpad(c.i::text, 12, '0'))::uuid, t.u(1),
       'Place ' || (p ->> 'key'), 30.2672, -97.7431, (p ->> 'createdAt')::timestamptz,
       case when (p ->> 'vetoed')::boolean then (p ->> 'createdAt')::timestamptz end
  from t.winner_cases c cross join lateral jsonb_array_elements(c.j -> 'places') p;
insert into place_votes(proposal_id, voter_id, place_id)
select ('d0000000-0000-0000-0000-' || lpad(c.i::text, 12, '0'))::uuid,
       t.u((row_number() over (partition by c.i order by v.key, g) + 1)::int), pl.id
  from t.winner_cases c
  cross join lateral jsonb_each_text(c.j -> 'votes') v(key, cnt)
  cross join lateral generate_series(1, v.cnt::int) g
  join proposal_places pl on pl.proposal_id = ('d0000000-0000-0000-0000-' || lpad(c.i::text, 12, '0'))::uuid
                         and pl.name = 'Place ' || v.key;
select t.eq('the shared file holds the six cases', (select count(*)::int from t.winner_cases), 6);
select t.eq('every case returns the expected winner',
  (select coalesce(string_agg(nm, ', '), 'none')
     from t.winner_cases c
    where friendcal_place_winner(('d0000000-0000-0000-0000-' || lpad(c.i::text, 12, '0'))::uuid)
          is distinct from (select (p ->> 'id')::uuid from jsonb_array_elements(c.j -> 'places') p where p ->> 'key' = c.j ->> 'winner')),
  'none');

-- ===========================================================================
-- 12. T14 the host's city. protects=the host sets a city while requesting, a friend cannot, a partial
--     city is rejected, the host cannot clear it, and no one changes it after lock; fails_when=a
--     friend changes the city, a name with null coordinates is stored, the host clears the city, or
--     the city changes on a locked plan; no_claim=whether the city is real. Section 4's no-city plan
--     is reused for the first set; the upgraded database also has old plans with no city at all.
-- ===========================================================================
create function t.city(pid uuid, uid uuid, nm text, lat text, lon text) returns t.outcome language sql as $$
  select t.call(format('update proposals set area_name = %L, area_lat = %L, area_lon = %L where id = %L', nm, lat, lon, pid), uid) $$;
grant execute on all functions in schema t to anon, authenticated, service_role;
select t.mkplan(t.pid(16), has_area => false);
select t.succeeds('the host sets a city on a plan that has none', t.city(t.pid(16), t.u(1), 'Austin, TX', '30.2672', '-97.7431'));
select t.eq('the city is stored', (select area_name || ' ' || area_lat || ' ' || area_lon from proposals where id = t.pid(16)), 'Austin, TX 30.2672 -97.7431');
select t.succeeds('the host replaces it while requesting', t.city(t.pid(16), t.u(1), 'Dallas, TX', '32.7767', '-96.797'));
select t.refuses('the host cannot clear it', t.city(t.pid(16), t.u(1), null, null, null), '22023', 'FC_AREA_REQUIRED');
select t.eq('the city is still Dallas', (select area_name from proposals where id = t.pid(16)), 'Dallas, TX');
select t.refuses('a name with null coordinates is rejected', t.city(t.pid(16), t.u(1), 'Houston, TX', null, null), '23514', null);
select t.refuses('setting only the name to null counts as clearing it', t.call(format('update proposals set area_name = null where id = %L', t.pid(16)), t.u(1)), '22023', 'FC_AREA_REQUIRED');
select t.refuses('a latitude out of range is rejected', t.city(t.pid(16), t.u(1), 'Nowhere', '91', '0'), '23514', null);
select t.refuses('a longitude out of range is rejected', t.city(t.pid(16), t.u(1), 'Nowhere', '0', '181'), '23514', null);
select t.eq('a friend''s update touches no row', (t.city(t.pid(16), t.u(2), 'Waco, TX', '31.5493', '-97.1467')).rows, 0);
select t.eq('so the city is unchanged', (select area_name from proposals where id = t.pid(16)), 'Dallas, TX');
select t.refuses('a locked plan''s city cannot change', t.city(t.pid(14), t.u(1), 'Waco, TX', '31.5493', '-97.1467'), '55000', 'FC_LOCKED');
select t.refuses('a cancelled plan''s city cannot change', t.city(t.pid(15), t.u(1), 'Waco, TX', '31.5493', '-97.1467'), '55000', 'FC_LOCKED');
select t.refuses('clearing the city of a locked plan answers LOCKED first', t.city(t.pid(14), t.u(1), null, null, null), '55000', 'FC_LOCKED');
select t.succeeds('a plan can be created with a city', t.call(format(
  'insert into proposals(id, title, window_start, window_end, created_by, area_name, area_lat, area_lon) values (%L, ''With city'', now(), now() + interval ''1 day'', %L, ''Austin, TX'', 30.2672, -97.7431)',
  gen_random_uuid(), t.u(1)), t.u(1)));
select t.succeeds('a plan can be created without one', t.call(format(
  'insert into proposals(id, title, window_start, window_end, created_by) values (%L, ''No city'', now(), now() + interval ''1 day'', %L)',
  gen_random_uuid(), t.u(1)), t.u(1)));
select t.succeeds('a title edit does not touch the city and is allowed on a plan with none',
  t.call(format('update proposals set title = ''Renamed'' where id = %L', t.pid(2)), t.u(1)));
-- Boundaries of the name: measured after btrim, in code points.
select t.refuses('a name of one space is refused', t.city(t.pid(16), t.u(1), ' ', '30', '-97'), '23514', null);
select t.succeeds('a 120-character name padded with spaces is accepted', t.city(t.pid(16), t.u(1), '   ' || repeat('a', 120) || '   ', '30', '-97'));
select t.refuses('a 121-character trimmed name is refused', t.city(t.pid(16), t.u(1), repeat('a', 121), '30', '-97'), '23514', null);
select t.succeeds('120 multi-byte characters are accepted (code points, not bytes)', t.city(t.pid(16), t.u(1), repeat('é', 120), '30', '-97'));

-- ===========================================================================
-- 13. T15 internal functions are not callable from a client. protects=the guard, the winner rule and
--     the plan-lock helper cannot be reached from outside; fails_when=authenticated keeps EXECUTE
--     through Supabase's default privileges; no_claim=functions added later.
-- ===========================================================================
select t.refuses('authenticated cannot call the guard directly',
  t.call(format('select friendcal_places_plan(%L)', t.pid(1)), t.u(1)), '42501', null);
select t.refuses('anon cannot call the guard directly',
  t.call(format('select friendcal_places_plan(%L)', t.pid(1)), null, 'anon'), '42501', null);
select t.refuses('authenticated cannot call the winner rule directly',
  t.call(format('select friendcal_place_winner(%L)', t.pid(1)), t.u(1)), '42501', null);
select t.refuses('anon cannot call the winner rule directly',
  t.call(format('select friendcal_place_winner(%L)', t.pid(1)), null, 'anon'), '42501', null);
select t.refuses('authenticated cannot call the plan-lock helper directly',
  t.call(format('select friendcal_lock_plans(array[%L]::uuid[])', t.pid(1)), t.u(1)), '42501', null);
select t.refuses('anon cannot call the plan-lock helper directly',
  t.call(format('select friendcal_lock_plans(array[%L]::uuid[])', t.pid(1)), null, 'anon'), '42501', null);

-- ===========================================================================
-- 14. T13 account deletion. protects=votes on collecting plans go, votes on locked plans stay,
--     suggestions stay, and a plan the leaver hosted keeps its votes as history once cancelled;
--     fails_when=a leaver's vote still decides a winner, or a locked plan's tally changes;
--     no_claim=the app-side "A friend" rendering, covered by #12. Last, because it deactivates u8
--     and u9.
-- ===========================================================================
select t.mkplan(t.pid(20));                              -- u8 voted here; still collecting
select t.mkplan(t.pid(21), 'locked');                    -- u8 voted here; locked
select t.mkplan(t.pid(22), creator => t.u(9));           -- u9 hosts and voted on their own plan
select t.place(t.plid(201), t.pid(20), t.u(2), 'Open plan place');
select t.place(t.plid(202), t.pid(20), t.u(8), 'u8 suggested this');
select t.place(t.plid(203), t.pid(21), t.u(2), 'Locked plan place');
select t.place(t.plid(204), t.pid(21), t.u(8), 'u8 suggested this too');
select t.place(t.plid(205), t.pid(22), t.u(2), 'u9''s plan place');
select t.cast(t.pid(20), t.u(8), t.plid(201));
select t.cast(t.pid(20), t.u(3), t.plid(202));
select t.cast(t.pid(21), t.u(8), t.plid(203));
select t.cast(t.pid(22), t.u(9), t.plid(205));
select t.cast(t.pid(22), t.u(3), t.plid(205));
update proposals set locked_place_id = t.plid(203) where id = t.pid(21);
select t.succeeds('u8 deletes their account', t.call('select delete_account()', t.u(8)));
select t.eq('u8''s vote on the collecting plan is gone', (select count(*)::int from place_votes where voter_id = t.u(8) and proposal_id = t.pid(20)), 0);
select t.eq('u8''s vote on the locked plan stays', (select count(*)::int from place_votes where voter_id = t.u(8) and proposal_id = t.pid(21)), 1);
select t.eq('u8''s suggestions stay on both plans', (select count(*)::int from proposal_places where suggested_by = t.u(8)), 2);
select t.eq('other people''s votes are untouched', (select count(*)::int from place_votes where voter_id = t.u(3) and proposal_id = t.pid(20)), 1);
select t.eq('the stored winner of the locked plan is unchanged', (select locked_place_id from proposals where id = t.pid(21)), t.plid(203));
select t.succeeds('a second deletion still succeeds', t.call('select delete_account()', t.u(8)));
select t.eq('and still changes nothing', (select count(*)::int from place_votes where voter_id = t.u(8)), 1);
select t.succeeds('u9 deletes their account', t.call('select delete_account()', t.u(9)));
select t.eq('u9''s plan is cancelled', (select status from proposals where id = t.pid(22)), 'cancelled');
select t.eq('votes on the cancelled plan stay as history', (select count(*)::int from place_votes where proposal_id = t.pid(22)), 2);
select t.refuses('a deleted account cannot suggest', t.suggest(t.pid(20), t.u(8), 'X'), '42501', 'FC_ACCOUNT_DELETED');
select t.refuses('...nor vote', t.vote(t.pid(20), t.plid(201), t.u(8)), '42501', 'FC_ACCOUNT_DELETED');

select 'places tests: all passed' as result;
