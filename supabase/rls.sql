-- RLS: read scoping and the stealth boundary.
-- Idempotent: run after schema.sql + schema_additions.sql on a new project, or on its own to
-- upgrade an existing one. Safe to re-run, in either load mode.
--
-- Load modes both matter. schema.sql:2 tells a human to paste these files into the Supabase SQL
-- editor, which runs them statement-by-statement; a cautious operator wraps them in a single
-- transaction instead. Before this wave the file installed 7 of 8 policies in the first mode and 0
-- in the second (one bad cast aborted the transaction), so a deployment could half-succeed in
-- silence. scripts/test-sql.sh now asserts the full policy count in BOTH modes.
--
-- ===========================================================================
-- The invariant (docs/designs/friendcal-hub.md): an excluded viewer must see an indistinguishable
-- grey Busy block. Not an absent row -- an absent row is itself the tell. So busy_blocks rows stay
-- readable by everyone, and the columns that say what the block MEANS are removed by privilege,
-- not by policy. RLS has no column granularity; GRANT does.
--
-- Three tables, three different treatments, for three different reasons:
--   proposals          -> row-scoped. A plan you are not party to should not exist for you.
--   availability_slots -> row-scoped. A hold is a private signal about your own calendar.
--   busy_blocks        -> rows stay readable, columns restricted. Hiding the row breaks the
--                         invariant above; hiding hidden_from/event_id/source_proposal_id is the
--                         whole point.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1) busy_blocks. Every authenticated viewer gets every row, so an excluded viewer is byte-for-byte
--    indistinguishable from a stranger. The correlation columns are handled by GRANT, at the bottom.
-- ---------------------------------------------------------------------------
drop policy if exists "read busy if not excluded" on busy_blocks;
drop policy if exists "busy_read_all_authed" on busy_blocks;
create policy "busy_read_all_authed"
  on busy_blocks for select
  to authenticated
  using (true);

drop policy if exists "busy_write_own" on busy_blocks;
create policy "busy_write_own"
  on busy_blocks for insert
  to authenticated
  with check (auth.uid() = user_id);

drop policy if exists "busy_update_own" on busy_blocks;
create policy "busy_update_own"
  on busy_blocks for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists "busy_delete_own" on busy_blocks;
create policy "busy_delete_own"
  on busy_blocks for delete
  to authenticated
  using (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- 2) events: an excluded viewer cannot reach the event at all.
--
--    The previous form was `not (auth.uid() = any((select hidden_from from busy_blocks where ...)))`,
--    which is broken three ways at once. It does not type-check (a scalar subquery of uuid[] against
--    `= any`, so `uuid = uuid[]` -- this is the error that aborted the whole file); with two
--    busy_blocks for one event it would raise "more than one row returned"; and when the subquery
--    finds nothing, `= any(NULL)` is NULL, which RLS reads as "not excluded".
--
--    Correct semantics are ANY-across-rows: a viewer is excluded if ANY block for this event lists
--    them. An `exists` says exactly that, and is NULL-safe and multi-row-safe by construction.
--
--    The check cannot be inlined, and this is worth knowing before anyone tries: a policy MAY read a
--    column of its OWN table that the querying role was revoked from (column privileges are checked
--    against the columns the user's query names, not the policy's internals), but it may NOT read
--    another table's columns that way. The events policy needs busy_blocks.hidden_from, a different
--    table, so an inlined `exists` fails with "permission denied for table busy_blocks" once the
--    column grants at the bottom of this file land. Both behaviours verified on 15.15.
--
--    Hence a security definer helper. The outside voice's objection to one (F5) was that a callable
--    "is this person excluded?" function is an oracle for exactly what the column revoke hides: ask
--    it per candidate id and read off the guest list. That objection is answered by the SIGNATURE,
--    not by withholding the grant -- withholding it cannot work, because a policy calling a function
--    the querying role cannot execute fails with "permission denied for function" (also verified).
--
--    stealth_excluded(p_event) takes NO user parameter and reads auth.uid() itself. You can only ask
--    it about yourself, and the answer is something you could already infer from whether the event
--    row is visible to you, so it reveals nothing the policy did not already tell you. The absence
--    of that second parameter IS the security property, and rls_test.sql asserts no two-argument
--    form exists. Same discipline as delete_account(): the caller never names the subject.
-- ---------------------------------------------------------------------------
create or replace function stealth_excluded(p_event uuid) returns boolean
language sql
stable
security definer
set search_path = public
as $$
  -- ANY-across-rows: excluded if ANY block for this event lists the caller. `exists` is NULL-safe
  -- and multi-row-safe, which the previous `= any((select ...))` form was neither.
  select exists (
    select 1 from busy_blocks b
     where b.event_id = p_event
       and auth.uid() = any (b.hidden_from)
  )
$$;
revoke all on function stealth_excluded(uuid) from public, anon;
grant execute on function stealth_excluded(uuid) to authenticated;

drop policy if exists "hide stealth events from excluded" on events;
drop policy if exists "events_read_unless_excluded" on events;
create policy "events_read_unless_excluded"
  on events for select
  to authenticated
  using (
    auth.uid() is not null
    and not stealth_excluded(events.id)
    and (
      host_id = auth.uid()
      or auth.uid() = any (attendee_ids)
    )
  );

drop policy if exists "events_write_own" on events;
create policy "events_write_own"
  on events for insert
  to authenticated
  with check (auth.uid() = host_id);

drop policy if exists "events_update_own" on events;
create policy "events_update_own"
  on events for update
  to authenticated
  using (auth.uid() = host_id)
  with check (auth.uid() = host_id);

-- ---------------------------------------------------------------------------
-- 3) availability_slots: your holds are yours. The one other reader is the creator of the plan a
--    hold was placed for -- that is how the creator's heatmap is built. Nobody else, ever.
-- ---------------------------------------------------------------------------
drop policy if exists "read availability for circles" on availability_slots;
drop policy if exists "availability_read_own_or_as_plan_creator" on availability_slots;
create policy "availability_read_own_or_as_plan_creator"
  on availability_slots for select
  to authenticated
  using (
    auth.uid() is not null
    and (
      user_id = auth.uid()
      or exists (
        select 1 from proposals p
         where p.id = availability_slots.source_proposal_id
           and p.created_by = auth.uid()
      )
    )
  );

drop policy if exists "write own availability" on availability_slots;
create policy "write own availability"
  on availability_slots for insert
  to authenticated
  with check (auth.uid() = user_id);

drop policy if exists "update own availability" on availability_slots;
create policy "update own availability"
  on availability_slots for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists "delete own availability" on availability_slots;
create policy "delete own availability"
  on availability_slots for delete
  to authenticated
  using (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- 4) proposals: readable by the people party to the plan, and never by an excluded id (D12).
--    The exclusion test comes FIRST and is independent of membership, so an excluded id that holds
--    a forwarded link and manages to join still reads zero rows -- exclusion outranks membership.
-- ---------------------------------------------------------------------------
--    The predicate is a FUNCTION, not an inline expression, because it has a second caller:
--    my_commitments() is security definer, so it reads proposals as the owner and the owner bypasses
--    RLS -- it must re-apply this exact test or it hands back the title of every plan behind every
--    block the caller holds, including plans they were excluded from (CEO review C2). Two
--    hand-written copies of the same predicate that must agree forever is the hand-synced-list
--    failure the review called this wave's worst structural risk, so there is exactly one copy.
--
--    It takes the row's COLUMNS rather than an id, deliberately: an id-taking version would add a
--    primary-key lookup per row to a policy that already scans, while the columns are in hand.
--    `stable`, not `immutable`, because auth.uid() is stable.
create or replace function proposal_is_readable(
  p_hidden_from uuid[],
  p_created_by uuid,
  p_distribution jsonb
) returns boolean
language sql
stable
as $$
  -- Exclusion first and unconditionally (D12): it outranks membership, so an excluded id who is
  -- also somehow a recipient still reads nothing.
  select not (auth.uid() = any (coalesce(p_hidden_from, '{}'::uuid[])))
     and (
       p_created_by = auth.uid()
       or (coalesce(p_distribution, '{}'::jsonb) -> 'recipientIDs') ? auth.uid()::text
     )
$$;
revoke all on function proposal_is_readable(uuid[], uuid, jsonb) from public, anon;
grant execute on function proposal_is_readable(uuid[], uuid, jsonb) to authenticated;

drop policy if exists "proposals_read_involved" on proposals;
create policy "proposals_read_involved"
  on proposals for select
  to authenticated
  using (
    auth.uid() is not null
    and proposal_is_readable(hidden_from, created_by, distribution)
  );

-- A client may create its own plan, and only in the one state a new plan can be in. Every
-- server-owned field must be at its default: a client cannot insert a plan that is already locked.
drop policy if exists "proposals_insert_own" on proposals;
create policy "proposals_insert_own"
  on proposals for insert
  to authenticated
  with check (
    created_by = auth.uid()
    and status = 'requesting'
    and locked_date is null
    and locked_end is null
    and hidden_from = '{}'::uuid[]
    and window_end > window_start
  );

-- Updates are the creator's alone, and the column-level guard below decides WHICH fields may move.
drop policy if exists "proposals_update_own" on proposals;
create policy "proposals_update_own"
  on proposals for update
  to authenticated
  using (created_by = auth.uid() and not (auth.uid() = any (hidden_from)))
  with check (created_by = auth.uid());

-- ---------------------------------------------------------------------------
-- 5) circles / circle_members: RLS on, and deliberately NO policy. RLS with zero policies denies
--    every row to every non-owner role, which is the correct state for tables nothing reads yet --
--    rather than the previous `using(true)` placeholder on availability_slots that stood in for them.
--    When membership-scoped reads ship, they get real policies and a test; until then they are shut.
-- ---------------------------------------------------------------------------
alter table circles enable row level security;
alter table circle_members enable row level security;

-- ---------------------------------------------------------------------------
-- 6) The sanitized view. Belt and braces over the column grants: the view cannot expose a
--    correlation column because it does not select one, so a future table-wide re-grant (Supabase
--    re-running its own bootstrap, say) cannot leak through this path.
--    security_invoker = true so the base table's RLS still applies to the caller. Without it the
--    view would run as its owner and hand every caller every row. This is a Postgres 15 feature and
--    is why the SQL lane's floor is 15.
-- ---------------------------------------------------------------------------
drop view if exists sanitized_busy_blocks;
create view sanitized_busy_blocks with (security_invoker = true) as
  select
    id,
    user_id,
    lower(range) as range_start,
    upper(range) as range_end,
    created_at
  from busy_blocks;
grant select on sanitized_busy_blocks to authenticated;

-- ---------------------------------------------------------------------------
-- 7) proposals_edit_guard (F3): the fields only the server may move.
--
--    RLS decides which ROWS you may update; it cannot say "you may change the title but not the
--    status". A BEFORE UPDATE trigger can. lock_proposal() and join_proposal() need to move exactly
--    those fields, so the guard has to let them through.
--
--    It distinguishes them by DEFINER CONTEXT, not by a marker the caller sets. The obvious
--    implementation -- a transaction-local flag the trusted functions set with set_config() -- is
--    forgeable: set_config() is executable by anyone, so a client could set the flag itself and then
--    update status directly. Inside a `security definer` function owned by the table owner,
--    current_user IS the owner; a direct client update runs as `authenticated`. That difference
--    cannot be forged from the client, needs no secret, and needs no grant.
-- ---------------------------------------------------------------------------
-- SECURITY INVOKER, deliberately and load-bearingly. Declaring this `security definer` makes
-- current_user the function's OWNER on every call, so `current_user = v_owner` is always true and
-- the guard waves everything through -- it reads as a guard, installs as a guard, and enforces
-- nothing. Verified: with `security definer` a client UPDATE set status to 'locked' unopposed.
-- As SECURITY INVOKER, current_user is `authenticated` for a direct client UPDATE and the owner when
-- the UPDATE happens inside a security definer RPC, which is exactly the distinction being drawn.
create or replace function proposals_edit_guard() returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_owner text;
begin
  select r.rolname into v_owner
    from pg_class c join pg_roles r on r.oid = c.relowner
   where c.oid = 'public.proposals'::regclass;

  -- A trusted mutation: we are inside a security definer function owned by the table owner, or a
  -- privileged backend role. Let it move whatever it needs to.
  if current_user = v_owner or current_user = 'service_role' then
    return new;
  end if;

  if new.id is distinct from old.id
     or new.created_by     is distinct from old.created_by
     or new.status         is distinct from old.status
     or new.locked_date    is distinct from old.locked_date
     or new.locked_end     is distinct from old.locked_end
     or new.hidden_from    is distinct from old.hidden_from
     or new.distribution   is distinct from old.distribution
     or new.window_start   is distinct from old.window_start
     or new.window_end     is distinct from old.window_end
     or new.created_at     is distinct from old.created_at then
    raise exception 'this field is set by the server, not the client'
      using errcode = '42501', hint = 'FC_SERVER_OWNED_FIELD';
  end if;
  return new;
end $$;
revoke all on function proposals_edit_guard() from public, anon, authenticated;

drop trigger if exists proposals_edit_guard_trg on proposals;
create trigger proposals_edit_guard_trg
  before update on proposals
  for each row execute function proposals_edit_guard();

-- ---------------------------------------------------------------------------
-- 8) Column privileges (G4). THE ORDER HERE IS LOAD-BEARING.
--
--    `revoke select (hidden_from) on busy_blocks from authenticated` on its own is a NO-OP when a
--    table-wide `grant select` is already in place -- and Supabase grants exactly that to anon and
--    authenticated when a project is created. REVOKE of a column privilege removes column-specific
--    grants; it does not subtract from a table-wide grant. Verified on 15.15: after the column
--    revoke, `select hidden_from from busy_blocks` still returned the array and
--    has_column_privilege() still returned true. A deployment would look correct and protect nothing.
--
--    So: revoke SELECT on the TABLE, then grant SELECT back on exactly the allowed columns.
--    Consequence for clients: `select *` on busy_blocks is refused for authenticated. Every client
--    read must name its columns or go through sanitized_busy_blocks. Provenance and titles are
--    served by my_commitments() (see commitments.sql), never by a direct column read.
--
--    Any column added to busy_blocks after this runs is denied by default, which is the safe
--    direction -- but re-run this file after adding one you intend clients to read.
-- ---------------------------------------------------------------------------
--    The same trap applies to EVERY privilege, not just SELECT. Revoking SELECT alone and then
--    granting `update (title, ...)` leaves the table-wide UPDATE grant untouched, so the column list
--    adds nothing and a client can still write any column: verified, a client set status='locked'
--    through a column-restricted grant. So each table gets ONE `revoke all`, then exactly the
--    privileges clients are meant to have. DELETE and TRUNCATE have no column form -- they are
--    whole-row by nature -- so where a client may delete, the row policy is what scopes it.
revoke all on busy_blocks from authenticated, anon;
grant select (id, user_id, range, visibility, created_at) on busy_blocks to authenticated;
grant insert (user_id, range, visibility) on busy_blocks to authenticated;
grant update (range, visibility) on busy_blocks to authenticated;
grant delete on busy_blocks to authenticated;  -- scoped to own rows by busy_delete_own

-- proposals.hidden_from is the same kind of secret: it names who was deliberately left out.
-- No DELETE for clients at all: removing a plan goes through delete_account()/cancellation, which
-- have to release holds and keep locked plans coherent. A bare DELETE would skip all of that.
revoke all on proposals from authenticated, anon;
grant select (id, title, window_start, window_end, created_by, distribution, status,
              locked_date, locked_end, created_at) on proposals to authenticated;
grant insert (id, title, window_start, window_end, created_by, distribution, status,
              locked_date, locked_end, created_at) on proposals to authenticated;
-- `distribution` is INSERTable but not UPDATEable, and the two lists must stay that way. A client
-- composes the recipient list when it creates the plan; changing it afterwards means admitting
-- someone, which has to consult hidden_from -- so it goes through join_proposal() and nothing else.
-- Granting UPDATE on it here would also contradict proposals_edit_guard, which lists distribution as
-- server-owned: the guard would win, leaving a grant that advertises a write that always fails.
grant update (title, window_start, window_end) on proposals to authenticated;

-- availability_slots and events hold no column-level secrets -- a hold is wholly yours, and an
-- event's attendee list is known to the people who can read the event at all -- so these are
-- whole-row grants scoped by their policies. They still need the `revoke all` first, to drop
-- TRUNCATE/REFERENCES/TRIGGER and to take anon off entirely.
revoke all on availability_slots from authenticated, anon;
grant select, insert, update, delete on availability_slots to authenticated;

revoke all on events from authenticated, anon;
grant select, insert, update on events to authenticated;

-- Nothing reads these yet, and RLS with no policy already denies every row. Taking the grants away
-- too means a future `create policy` cannot accidentally open a table nobody has designed reads for.
revoke all on circles, circle_members from authenticated, anon;

-- anon reads nothing, anywhere, full stop. Every policy above says `to authenticated`, but a missing
-- or mistaken policy should not be the only thing between an unauthenticated caller and a table.
-- Blanket rather than enumerated, so a table added later is not quietly left open; and the default
-- privilege is withdrawn too, so the NEXT table created does not hand anon a grant on creation.
-- (Supabase's own bootstrap grants anon ALL on new tables, which is what this undoes.)
revoke all on all tables in schema public from anon;
alter default privileges in schema public revoke all on tables from anon;

-- ---------------------------------------------------------------------------
-- 9) Self-check. In single-transaction mode a failure here rolls the whole file back rather than
--    leaving a half-installed policy set; statement-by-statement it prints the mismatch.
-- ---------------------------------------------------------------------------
do $$
declare
  v_leaky int;
  v_tables text;
begin
  select count(*) into v_leaky
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where c.relkind = 'v' and n.nspname = 'public'
     and not coalesce(c.reloptions, '{}') @> array['security_invoker=true'];
  if v_leaky > 0 then
    raise exception 'rls.sql: % view(s) in public are not security_invoker', v_leaky;
  end if;

  select string_agg(c.relname, ', ') into v_tables
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'
     and c.relname in ('busy_blocks', 'events', 'availability_slots', 'proposals', 'circles', 'circle_members')
     and not c.relrowsecurity;
  if v_tables is not null then
    raise exception 'rls.sql: row level security is off on %', v_tables;
  end if;

  if has_column_privilege('authenticated', 'busy_blocks', 'hidden_from', 'SELECT') then
    raise exception 'rls.sql: authenticated can still select busy_blocks.hidden_from -- the column revoke did not take (is a table-wide grant still in place?)';
  end if;
  if has_column_privilege('authenticated', 'proposals', 'hidden_from', 'SELECT') then
    raise exception 'rls.sql: authenticated can still select proposals.hidden_from';
  end if;

  -- A table-wide grant silently defeats every column-level grant sitting beside it: the column list
  -- is additive, never subtractive. information_schema.table_privileges lists ONLY table-level
  -- grants (column grants live in column_privileges), so anything here on a column-restricted table
  -- means the restriction is decorative. This is the check that catches the mistake.
  select string_agg(table_name || '.' || privilege_type, ', ' order by table_name, privilege_type)
    into v_tables
    from information_schema.table_privileges
   where grantee = 'authenticated' and table_schema = 'public'
     and table_name in ('busy_blocks', 'proposals')
     and privilege_type in ('SELECT', 'INSERT', 'UPDATE');
  if v_tables is not null then
    raise exception 'rls.sql: table-wide grant(s) still held by authenticated, which defeats the column grants: %', v_tables;
  end if;

  select string_agg(distinct table_name, ', ' order by table_name) into v_tables
    from information_schema.table_privileges
   where grantee = 'anon' and table_schema = 'public';
  if v_tables is not null then
    raise exception 'rls.sql: anon still holds privileges on %', v_tables;
  end if;

  raise notice 'rls.sql: policy set, views and column grants verified';
end $$;

-- Push sanitization: the Edge Function `push-notify` queries with service_role and must strip the
-- title for everyone in hidden_from before handing the payload to APNs. The column grants above do
-- not constrain service_role, so that stripping is the only thing protecting the push path.
