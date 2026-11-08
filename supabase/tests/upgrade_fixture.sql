-- Populated fixtures for the upgrade path (eng review F9).
--
-- Loaded into the `upgrade_check` database AFTER the baseline schema (origin/main's schema.sql) and
-- BEFORE this wave's SQL. An empty database proves only that the new SQL parses; these rows prove it
-- does not destroy, lock out or fail against data that already exists. Every row here is shaped like
-- something a real project would already hold when the wave is applied:
--   - a locked proposal with Busy blocks already promoted (no source_proposal_id: the column the wave
--     adds must backfill as NULL, not error on the FK or the `on delete set null`)
--   - a requesting proposal with live softHolds, one with a NULL expiry (the hold that never expires)
--   - a stealth event with two busy_blocks carrying DISAGREEING hidden_from, which is the case the
--     scalar-subquery form of the events policy cannot express
--   - a user who will be the deletion subject, so the wave's users columns backfill over real rows
\set ON_ERROR_STOP 1

insert into users(id, display_name) values
  ('00000000-0000-0000-0000-0000000000a1', 'upgrade-alice'),
  ('00000000-0000-0000-0000-0000000000a2', 'upgrade-bob'),
  ('00000000-0000-0000-0000-0000000000a3', 'upgrade-carol'),
  ('00000000-0000-0000-0000-0000000000a4', 'upgrade-jalen');

-- A plan that was already locked before the upgrade.
insert into proposals(id, title, window_start, window_end, created_by, distribution, status, locked_date, locked_end)
values ('00000000-0000-0000-0000-0000000000b1', 'Already Locked',
        '2026-11-10 00:00Z', '2026-11-24 00:00Z', '00000000-0000-0000-0000-0000000000a1',
        jsonb_build_object('mode', 'newGroup', 'recipientIDs',
          jsonb_build_array('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a2')),
        'locked', '2026-11-14 18:00Z', '2026-11-14 19:30Z');

-- A plan still gathering holds, including one hold with no expiry at all.
insert into proposals(id, title, window_start, window_end, created_by, distribution)
values ('00000000-0000-0000-0000-0000000000b2', 'Still Requesting',
        '2026-12-01 00:00Z', '2026-12-14 00:00Z', '00000000-0000-0000-0000-0000000000a2',
        jsonb_build_object('mode', 'newGroup', 'recipientIDs',
          jsonb_build_array('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a3')));

insert into availability_slots(user_id, range, source_proposal_id, state, expires_at) values
  ('00000000-0000-0000-0000-0000000000a1', '[2026-12-05 18:00Z,2026-12-05 20:00Z)',
   '00000000-0000-0000-0000-0000000000b2', 'softHold', now() + interval '30 days'),
  ('00000000-0000-0000-0000-0000000000a3', '[2026-12-05 18:00Z,2026-12-05 20:00Z)',
   '00000000-0000-0000-0000-0000000000b2', 'softHold', null);

-- Busy blocks promoted by the already-locked plan. No provenance column exists yet on the baseline.
insert into busy_blocks(id, user_id, range, visibility) values
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000a1',
   '[2026-11-14 18:00Z,2026-11-14 19:30Z)', 'public'),
  ('00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000a2',
   '[2026-11-14 18:00Z,2026-11-14 19:30Z)', 'public');

-- A stealth event whose two busy_blocks DISAGREE about who is excluded: a1's row hides Jalen, a3's
-- row hides nobody. Any policy that reads hidden_from through a scalar subquery either raises
-- "more than one row returned" or silently picks one row; only ANY-across-rows semantics is correct.
insert into events(id, title, date, venue, host_id, attendee_ids, busy_block_ids) values
  ('00000000-0000-0000-0000-0000000000d1', 'Surprise Brunch', '2026-12-20 11:00Z', 'Rosewood',
   '00000000-0000-0000-0000-0000000000a1',
   array['00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a3']::uuid[],
   array['00000000-0000-0000-0000-0000000000c3', '00000000-0000-0000-0000-0000000000c4']::uuid[]);

insert into busy_blocks(id, user_id, range, visibility, hidden_from, event_id) values
  ('00000000-0000-0000-0000-0000000000c3', '00000000-0000-0000-0000-0000000000a1',
   '[2026-12-20 11:00Z,2026-12-20 13:00Z)', 'stealth',
   array['00000000-0000-0000-0000-0000000000a4']::uuid[], '00000000-0000-0000-0000-0000000000d1'),
  ('00000000-0000-0000-0000-0000000000c4', '00000000-0000-0000-0000-0000000000a3',
   '[2026-12-20 11:00Z,2026-12-20 13:00Z)', 'stealth',
   '{}'::uuid[], '00000000-0000-0000-0000-0000000000d1');
