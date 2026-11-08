-- Lock RPC for FriendCal (review D5). Idempotent: run after schema.sql + schema_additions.sql on a
-- new project, or on its own to upgrade an existing database (Supabase SQL editor). Safe to re-run.

alter table proposals add column if not exists locked_end timestamptz;

-- ---------------------------------------------------------------------------
-- THE RETURN TYPE. `returns setof busy_blocks` would hand the caller the whole row -- including
-- hidden_from, event_id and source_proposal_id. A function's return value is NOT column-privilege
-- checked, so that return type walks straight past the column grants in rls.sql and undoes the
-- stealth boundary for anyone who calls the RPC. It would also widen silently the moment a column is
-- added to busy_blocks, which is exactly how this nearly shipped.
--
-- So the RPC returns a named narrow type instead. Adding a column to busy_blocks now changes nothing
-- about the wire contract, and the only way to widen it is to edit this type on purpose.
-- ---------------------------------------------------------------------------
do $$ begin
  create type busy_block_public as (
    id uuid,
    user_id uuid,
    range_start timestamptz,
    range_end timestamptz
  );
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- THE LOCKING PROTOCOL (outside voice F1). Every function that takes per-user locks takes them
-- here, in one place, in one order: advisory locks keyed on user id, ascending. Two functions that
-- lock the same people in different orders deadlock, and the bug only appears under concurrency, so
-- the ordering cannot live as a comment in each caller -- it lives in this function and nowhere else.
-- Callers: lock_proposal(), delete_account(), join_proposal().
-- ---------------------------------------------------------------------------
create or replace function friendcal_lock_users(p_users uuid[]) returns void
language plpgsql
as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('friendcal.busy:' || u::text, 0))
     from unnest(coalesce(p_users, '{}'::uuid[])) as u
    order by u;
end $$;
revoke all on function friendcal_lock_users(uuid[]) from public, anon, authenticated;

-- Lock a proposal atomically (D3, D12; review D5). The creator picks the common window; the server
-- re-derives who is free instead of trusting the client: a recipient counts when the union of their
-- unexpired softHolds for this proposal covers the window (range_agg merges touching ranges, like
-- HeatmapBuilder.merge) and they have no Busy block over it yet. The quorum is fixed here, never a
-- parameter. Concurrent locks and hold edits are serialized (see below). One transaction sets status
-- and both ends, inserts one window-sized Busy block per free recipient -- stamped with the plan that
-- created it (G3) -- and clears the proposal's softHolds; any refusal rolls the whole lock back.
--
-- Every refusal carries an FC_* hint as well as a SQLSTATE. The SQLSTATE is the wire contract; the
-- hint is the stable identifier UserFacingError maps to a sentence. SQLSTATEs are reused across
-- different refusals (three distinct 22023s here), so the hint is the only thing that tells them
-- apart -- the client must never parse the message text.
-- Tests: supabase/tests/lock_proposal_test.sql and the concurrency checks in scripts/test-sql.sh.
drop function if exists lock_proposal(uuid, timestamptz, timestamptz, numeric);
drop function if exists lock_proposal(uuid, timestamptz, timestamptz);
create or replace function lock_proposal(p_id uuid, p_start timestamptz, p_end timestamptz)
returns setof busy_block_public
language plpgsql
security definer
set search_path = public
as $$
declare
  c_quorum constant numeric := 0.8; -- matches ProposalService.quorumThreshold
  v_prop proposals%rowtype;
  v_window tstzrange := tstzrange(p_start, p_end, '[)');
  v_recipients uuid[];
  v_total int;
  v_free int;
  v_covering uuid[];
begin
  select * into v_prop from proposals where id = p_id for update;
  if not found then
    raise exception 'proposal % not found', p_id using errcode = 'P0002', hint = 'FC_NOT_FOUND';
  end if;
  if auth.uid() is null or v_prop.created_by is null or v_prop.created_by <> auth.uid() then
    raise exception 'only the proposal creator can lock it' using errcode = '42501', hint = 'FC_NOT_CREATOR';
  end if;
  if v_prop.status <> 'requesting' then
    raise exception 'proposal is %, not requesting', v_prop.status using errcode = '55000', hint = 'FC_LOCKED';
  end if;
  if p_start is null or p_end is null
     or p_end - p_start < interval '60 minutes' or p_start < v_prop.window_start or p_end > v_prop.window_end then
    raise exception 'lock window must be at least 60 minutes inside the proposal window'
      using errcode = '22023', hint = 'FC_WINDOW';
  end if;

  select coalesce(array_agg(distinct r::uuid), '{}') into v_recipients
    from jsonb_array_elements_text(coalesce(v_prop.distribution -> 'recipientIDs', '[]'::jsonb)) as r;
  v_total := cardinality(v_recipients);
  if v_total = 0 then
    raise exception 'no recipients to lock' using errcode = '22023', hint = 'FC_NO_RECIPIENTS';
  end if;

  -- Serialize before counting, through the one shared protocol. Locks over the same people take
  -- these advisory locks in the same sorted order (no deadlock), so the later one sees the earlier
  -- one's Busy blocks; locking this proposal's holds makes a concurrent hold edit finish first, so
  -- coverage reads the edited ranges.
  perform friendcal_lock_users(v_recipients);
  perform 1 from availability_slots
   where source_proposal_id = p_id and state = 'softHold'
     for update;

  select coalesce(array_agg(c.user_id), '{}') into v_covering
    from (select s.user_id
            from availability_slots s
           where s.source_proposal_id = p_id
             and s.state = 'softHold'
             and s.user_id = any (v_recipients)
             and (s.expires_at is null or s.expires_at > now())
             and not exists (select 1 from busy_blocks b
                              where b.user_id = s.user_id and b.range && v_window
                                and b.visibility in ('public', 'stealth'))
           group by s.user_id
          having range_agg(s.range) @> v_window) as c;
  v_free := cardinality(v_covering);
  if v_free::numeric / v_total < c_quorum then
    raise exception 'need % percent free, only % percent', round(c_quorum * 100), round(v_free * 100.0 / v_total)
      using errcode = '22023', hint = 'FC_QUORUM';
  end if;

  update proposals set status = 'locked', locked_date = p_start, locked_end = p_end where id = p_id;
  delete from availability_slots where source_proposal_id = p_id and state = 'softHold';
  begin
    return query
      insert into busy_blocks (user_id, range, visibility, source_proposal_id)
      select u, v_window, 'public', p_id from unnest(v_covering) as u
      returning id, user_id, lower(range), upper(range);
  exception when exclusion_violation then
    -- A recipient added their own Busy block mid-lock (they take no advisory lock). Refuse without
    -- echoing the constraint's DETAIL, which would show that person's busy range to the caller.
    raise exception 'availability changed while locking; try again'
      using errcode = '40001', hint = 'FC_CHANGED';
  end;
end;
$$;
-- Supabase's default privileges grant execute to anon directly, so revoking from public is not enough.
revoke all on function lock_proposal(uuid, timestamptz, timestamptz) from public, anon;
grant execute on function lock_proposal(uuid, timestamptz, timestamptz) to authenticated;
