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
