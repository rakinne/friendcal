-- Columns this wave adds to the Phase 1 schema. Idempotent in the lock_proposal.sql sense: run it
-- after schema.sql on a new project, or on its own to upgrade an existing one. Safe to re-run.
--
-- These live here rather than in schema.sql because schema.sql is NOT idempotent -- it has 7
-- `create table` statements and only circles/circle_members are guarded, so re-running it errors on
-- the first one. Rollback is `git revert` plus the recovery procedure in TODOS.md, never "re-run the
-- prior SQL". Keeping the wave's columns in their own re-runnable file is what makes the upgrade
-- path testable at all (scripts/test-sql.sh applies this over a populated origin/main database).
--
-- Every policy, view and function in the files that follow may assume these columns exist.

-- D12: exclusion rides on the proposal itself, so an excluded id that somehow holds the link still
-- reads zero rows. `join_proposal` consults it before admitting anyone.
alter table proposals add column if not exists hidden_from uuid[] not null default '{}';

-- G3: provenance. A Busy block that came from a locked plan points back at it, so "My commitments"
-- can say WHICH plan made you busy instead of showing an unattributed grey block.
-- `on delete set null`: deleting a plan must not delete the time people have already committed to.
alter table busy_blocks add column if not exists source_proposal_id uuid;
do $$ begin
  alter table busy_blocks add constraint busy_blocks_source_proposal_id_fkey
    foreign key (source_proposal_id) references proposals(id) on delete set null;
exception when duplicate_object then null; end $$;

-- E5: deletion leaves an anonymized tombstone rather than a hole. The row survives so that a locked
-- plan's attendee list and everyone else's Busy blocks stay coherent; `deleted_at` is what makes the
-- account inactive. See users_auth.sql for is_active() and delete_account().
alter table users add column if not exists deleted_at timestamptz;

-- P-1: the proposals read policy tests recipient membership inside `distribution -> 'recipientIDs'`
-- on every row. Without an index that is a sequential scan plus a jsonb containment check per row.
-- Default jsonb_ops (not jsonb_path_ops) because the policy uses the `?` existence operator.
create index if not exists idx_proposals_recipient_ids
  on proposals using gin ((distribution -> 'recipientIDs'));

-- Provenance lookups go the other way too: "which blocks came from this plan?" when a plan is
-- cancelled or deleted.
create index if not exists idx_busy_blocks_source_proposal
  on busy_blocks (source_proposal_id) where source_proposal_id is not null;

-- ---------------------------------------------------------------------------
-- Place voting (#10, #11): the host's city, the frozen winner, and the two tables.
-- Server rules live in places.sql, lock_proposal.sql, users_auth.sql and rls.sql.
-- ---------------------------------------------------------------------------
alter table proposals add column if not exists area_name text;
alter table proposals add column if not exists area_lat double precision;
alter table proposals add column if not exists area_lon double precision;
alter table proposals add column if not exists locked_place_id uuid;

-- Who is "in" on a locked plan, and when it locked. Written by lock_proposal() alone (no client
-- INSERT/UPDATE grant, see rls.sql). The client cannot derive this: busy_blocks.source_proposal_id is
-- unreadable to it on purpose. Joins are refused once a plan is locked, so there is no post-lock list.
alter table proposals add column if not exists locked_attendee_ids uuid[] not null default '{}';
alter table proposals add column if not exists locked_at timestamptz;
-- Plans locked before this column existed: the attendees are the people the lock gave a Busy block.
update proposals p
   set locked_attendee_ids = coalesce((select array_agg(b.user_id) from busy_blocks b where b.source_proposal_id = p.id), '{}')
 where p.status = 'locked' and p.locked_attendee_ids = '{}';

-- The city is all-or-none. A plan that predates this feature keeps all three null and passes. The
-- explicit `is not null` tests on the coordinates matter: a CHECK passes when its expression is NULL,
-- so without them a name with null coordinates would be accepted. The name is measured after btrim,
-- so a single space is refused and a 120-character name padded with spaces is accepted; char_length
-- counts code points, and the Swift side counts Unicode scalars to match.
do $$ begin
  alter table proposals add constraint proposals_area_all_or_none check (
    (area_name is null and area_lat is null and area_lon is null)
    or (area_name is not null and area_lat is not null and area_lon is not null
        and char_length(btrim(area_name)) between 1 and 120
        and area_lat between -90 and 90 and area_lon between -180 and 180));
exception when duplicate_object then null; end $$;

create table if not exists proposal_places (
  id uuid primary key default gen_random_uuid(),
  proposal_id uuid not null references proposals(id) on delete cascade,
  suggested_by uuid not null references users(id),
  name text not null check (char_length(name) between 1 and 120),
  address text check (address is null or char_length(address) <= 240),
  lat double precision not null check (lat between -90 and 90),
  lon double precision not null check (lon between -180 and 180),
  map_ref text check (map_ref is null or char_length(map_ref) <= 200),
  vetoed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (id, proposal_id)
);
create unique index if not exists proposal_places_map_ref
  on proposal_places (proposal_id, map_ref) where map_ref is not null;
create index if not exists proposal_places_by_proposal on proposal_places (proposal_id);

-- The primary key (proposal_id, voter_id) is what makes "one vote per person per plan" a database
-- fact. The composite foreign key is what makes "a vote's place belongs to the vote's plan" one too.
create table if not exists place_votes (
  proposal_id uuid not null references proposals(id) on delete cascade,
  voter_id uuid not null references users(id),
  place_id uuid not null,
  created_at timestamptz not null default now(),
  primary key (proposal_id, voter_id),
  foreign key (place_id, proposal_id)
    references proposal_places (id, proposal_id) on delete cascade
);
create index if not exists place_votes_by_place on place_votes (place_id);

do $$ begin
  alter table proposals add constraint proposals_locked_place_fkey
    foreign key (locked_place_id) references proposal_places(id) on delete set null;
exception when duplicate_object then null; end $$;
