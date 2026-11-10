-- Accounts: read scoping on users, the active-account check, and account deletion.
-- Idempotent: run after schema.sql + schema_additions.sql + rls.sql on a new project, or on its own
-- to upgrade an existing one. Safe to re-run.
--
-- The shape of deletion (CEO D13, E5, outside voice F8):
--   - The users row SURVIVES as an anonymized tombstone. It is not deleted. Other people's locked
--     plans reference this person; removing the row would leave a locked plan with an attendee
--     nobody can name, and Busy blocks other people already arranged their week around.
--   - The caller's still-open plans are cancelled, and EVERY softHold on those plans is released --
--     not just the caller's. Another participant's hold on a plan that no longer exists would go on
--     blocking their own choices, and a hold with expires_at = null never expires by itself.
--   - Locked plans keep their Busy blocks and the caller's attendee membership. Whether retaining
--     them is compatible with App Store guideline 5.1.1(v) is UNRESOLVED and must be settled before
--     the first submission (CEO review C7). This file implements retention; it does not settle it.

-- ---------------------------------------------------------------------------
-- 1) users: RLS, and reads scoped to yourself plus the people you share a plan with.
--
--    The co-participant branch deliberately does NOT re-check "and I am party to it too". It does
--    not need to: the `proposals` reference inside this policy is itself subject to proposals' RLS,
--    so `p` is already narrowed to the plans this caller may read -- which excludes plans they are
--    not party to AND plans they are hidden_from. Re-checking here would also mean reading
--    proposals.hidden_from, a column `authenticated` has no privilege on, and a policy may not read
--    another table's revoked columns. Composition does the work instead.
-- ---------------------------------------------------------------------------
alter table users enable row level security;

drop policy if exists "users_read_self_and_co_participants" on users;
create policy "users_read_self_and_co_participants"
  on users for select
  to authenticated
  using (
    auth.uid() is not null
    and (
      id = auth.uid()
      or exists (
        select 1 from proposals p
         where p.created_by = users.id
            or friendcal_has_recipient(p.distribution, users.id)
      )
    )
  );

-- You may create and edit only your own row, and you may never set your own deleted_at: deletion
-- goes through delete_account(), which has to cancel plans and release holds in the same transaction.
drop policy if exists "users_insert_self" on users;
create policy "users_insert_self"
  on users for insert
  to authenticated
  with check (id = auth.uid() and deleted_at is null);

drop policy if exists "users_update_self" on users;
create policy "users_update_self"
  on users for update
  to authenticated
  using (id = auth.uid() and deleted_at is null)
  with check (id = auth.uid() and deleted_at is null);

-- Same construction as rls.sql section 8, for the same reason: a table-wide grant makes a
-- column-level grant beside it decorative, so revoke the table first and grant back the columns.
-- deleted_at is readable -- a client needs to render a departed member as inactive -- but not
-- writable, which is what keeps deletion inside delete_account().
revoke all on users from authenticated, anon;
grant select (id, display_name, avatar_url, deleted_at) on users to authenticated;
grant insert (id, display_name, avatar_url) on users to authenticated;
grant update (display_name, avatar_url) on users to authenticated;

-- ---------------------------------------------------------------------------
-- 2) is_active(): is this account still a real person?
--
--    Returns false for an unknown id as well as a deleted one, so a tombstone and a stranger are
--    indistinguishable. security definer because it reads deleted_at across rows the caller may not
--    be able to select; safe to expose because uuids are unguessable, so it affords no enumeration.
-- ---------------------------------------------------------------------------
create or replace function is_active(p_user uuid) returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from users u where u.id = p_user and u.deleted_at is null)
$$;
revoke all on function is_active(uuid) from public, anon;
grant execute on function is_active(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3) delete_account(): one transaction, no parameters.
--
--    No user parameter, by design -- the same discipline as stealth_excluded(). The caller cannot
--    name a subject, so there is no shape of this call that deletes somebody else's account; it
--    reads auth.uid() itself. A parameter would make authorization a thing we have to check
--    correctly every time instead of a thing that cannot be expressed.
--
--    IDEMPOTENT by design, for C3. The app can be backgrounded or killed between sending this call
--    and seeing its result, and on relaunch it cannot know whether the transaction committed. So a
--    second call on an already-deleted account does not raise -- it returns the same summary shape
--    with already_deleted = true. A resumed deletion therefore always converges on "signed out, done"
--    without the client needing to special-case a refusal as success.
-- ---------------------------------------------------------------------------
create or replace function delete_account() returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_deleted_at timestamptz;
  v_cancelled uuid[];
  v_affected uuid[];
  v_released_others int := 0;
  v_released_own int := 0;
  v_locked int;
  v_open uuid[];
begin
  if v_uid is null then
    raise exception 'not signed in' using errcode = '42501', hint = 'FC_NOT_SIGNED_IN';
  end if;

  -- `for no key update`, not `for update` (#11, review R5). lock_proposal() inserts busy_blocks rows
  -- whose user_id references users(id), and that insert takes a key-share lock on this very row. A
  -- `for update` lock conflicts with key share, so this call (holding the row, waiting for a plan or
  -- an advisory lock) and a lock_proposal() (holding the plan and the advisory locks, inserting the
  -- Busy block) could wait on each other. `for no key update` allows key share, and still conflicts
  -- with another no-key-update and with the `for share` the place functions take, so deletions,
  -- votes and renames for one user still serialize.
  -- This stays correct only while the tombstone update below touches no column of a unique index on
  -- users: it sets display_name, avatar_url and deleted_at, and users has only its primary key. Add a
  -- unique index on one of those and the update escalates to a full `for update`, and the cycle
  -- returns without any test failing.
  select u.deleted_at into v_deleted_at from users u where u.id = v_uid for no key update;
  if not found then
    raise exception 'no such account' using errcode = 'P0002', hint = 'FC_NOT_FOUND';
  end if;

  -- Already done. Report the terminal state rather than refusing, so a resumed deletion converges.
  if v_deleted_at is not null then
    select count(*) into v_locked from proposals p where p.created_by = v_uid and p.status = 'locked';
    return jsonb_build_object(
      'already_deleted', true,
      'deleted_at', v_deleted_at,
      'cancelled_plans', 0,
      'released_holds', 0,
      'locked_plans_kept', v_locked);
  end if;

  -- The open plans this call must hold still: every one the caller created (they are about to be
  -- cancelled) and every one they voted on (their votes are about to be removed). Row-locked first,
  -- through the shared helper in id order, then collected: `for update` cannot appear in the same
  -- query as an aggregate (0A000), so this is separate statements -- the same shape lock_proposal()
  -- uses for the holds it is about to count. The lock is what stops a concurrent lock_proposal()
  -- from locking a plan this call is about to cancel, or tallying a vote this call is about to
  -- remove. It is taken before any advisory lock below: lock_proposal() takes the plan row first
  -- and the advisory locks second, and the opposite order deadlocks under concurrency.
  select coalesce(array_agg(distinct x.id), '{}') into v_open
    from (select p.id from proposals p
           where p.created_by = v_uid and p.status = 'requesting'
          union
          select p.id from proposals p join place_votes v on v.proposal_id = p.id
           where v.voter_id = v_uid and p.status = 'requesting') x;
  perform friendcal_lock_plans(v_open);
  -- A plan can change state while that lock was being waited for, so read the cancel list after it.
  select coalesce(array_agg(p.id), '{}') into v_cancelled
    from proposals p where p.created_by = v_uid and p.status = 'requesting';

  -- One locking protocol (F1): every person whose holds this call is about to touch, locked in the
  -- one shared order. Without this, delete_account and lock_proposal can take the same per-user
  -- locks in opposite orders and deadlock -- and only ever under concurrency.
  select coalesce(array_agg(distinct s.user_id), '{}') into v_affected
    from availability_slots s
   where s.source_proposal_id = any (v_cancelled) or s.user_id = v_uid;
  perform friendcal_lock_users(v_affected);

  update proposals set status = 'cancelled' where id = any (v_cancelled);

  -- The leaver's votes on plans that are still collecting: a departed person must not decide a
  -- winner. Plans this call just cancelled are no longer requesting, so their votes stay as history,
  -- as do the votes on locked plans. Suggestions are untouched; the tombstone row survives, so
  -- suggested_by stays valid and the app can show "A friend".
  delete from place_votes v
   using proposals p
   where v.voter_id = v_uid and p.id = v.proposal_id and p.status = 'requesting';

  -- E12 / outside voice F8: EVERY softHold on the cancelled plans, whoever placed it. This is the
  -- half that completes D13 -- cancelling the plan without releasing other people's holds leaves
  -- them blocked on a plan that no longer exists.
  with d as (
    delete from availability_slots
     where source_proposal_id = any (v_cancelled) and state = 'softHold'
     returning 1
  ) select count(*) into v_released_others from d;

  -- And the caller's own holds on everyone else's plans.
  with d as (
    delete from availability_slots
     where user_id = v_uid and state = 'softHold'
     returning 1
  ) select count(*) into v_released_own from d;

  -- Locked plans are left alone on purpose: their Busy blocks are time other people have already
  -- committed to, and the attendee list is what lets those people still see who they are meeting.
  select count(*) into v_locked from proposals p where p.created_by = v_uid and p.status = 'locked';

  -- The tombstone. The row stays; the identifying content goes.
  update users
     set display_name = 'Deleted account',
         avatar_url = null,
         deleted_at = now()
   where id = v_uid;

  return jsonb_build_object(
    'already_deleted', false,
    'deleted_at', now(),
    'cancelled_plans', cardinality(v_cancelled),
    'released_holds', v_released_others + v_released_own,
    'locked_plans_kept', v_locked);
end $$;
revoke all on function delete_account() from public, anon;
grant execute on function delete_account() to authenticated;

-- ---------------------------------------------------------------------------
-- 4) Self-check.
-- ---------------------------------------------------------------------------
do $$
begin
  if (select count(*) from pg_proc where proname = 'delete_account') <> 1
     or (select pronargs from pg_proc where proname = 'delete_account') <> 0 then
    raise exception 'users_auth.sql: delete_account() must exist exactly once and take no arguments';
  end if;
  if has_column_privilege('authenticated', 'users', 'deleted_at', 'UPDATE') then
    raise exception 'users_auth.sql: authenticated can write users.deleted_at, which bypasses delete_account()';
  end if;
  raise notice 'users_auth.sql: account policies, is_active() and delete_account() verified';
end $$;
