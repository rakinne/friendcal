-- Lock RPC for FriendCal (review D5). Idempotent: run after schema.sql on a new project, or on its own
-- to upgrade an existing database (Supabase SQL editor). Safe to re-run.

alter table proposals add column if not exists locked_end timestamptz;

-- Lock a proposal atomically (D3, D12; review D5). The creator picks the common window; the server
-- re-derives who is free instead of trusting the client: a recipient counts when the union of their
-- unexpired softHolds for this proposal covers the window (range_agg merges touching ranges, like
-- HeatmapBuilder.merge) and they have no Busy block over it yet. The quorum is fixed here, never a
-- parameter. Concurrent locks and hold edits are serialized (see below). One transaction sets status and both ends, inserts one window-sized Busy block per free
-- recipient and clears the proposal's softHolds; any refusal rolls the whole lock back.
-- Tests: supabase/tests/lock_proposal_test.sql and the concurrency checks in scripts/test-sql.sh.
drop function if exists lock_proposal(uuid, timestamptz, timestamptz, numeric);
create or replace function lock_proposal(p_id uuid, p_start timestamptz, p_end timestamptz)
returns setof busy_blocks
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
    raise exception 'proposal % not found', p_id using errcode = 'P0002';
  end if;
  if auth.uid() is null or v_prop.created_by is null or v_prop.created_by <> auth.uid() then
    raise exception 'only the proposal creator can lock it' using errcode = '42501';
  end if;
  if v_prop.status <> 'requesting' then
    raise exception 'proposal is %, not requesting', v_prop.status using errcode = '55000';
  end if;
  if p_start is null or p_end is null
     or p_end - p_start < interval '60 minutes' or p_start < v_prop.window_start or p_end > v_prop.window_end then
    raise exception 'lock window must be at least 60 minutes inside the proposal window' using errcode = '22023';
  end if;

  select coalesce(array_agg(distinct r::uuid), '{}') into v_recipients
    from jsonb_array_elements_text(coalesce(v_prop.distribution -> 'recipientIDs', '[]'::jsonb)) as r;
  v_total := cardinality(v_recipients);
  if v_total = 0 then
    raise exception 'no recipients to lock' using errcode = '22023';
  end if;

  -- Serialize before counting. Locks over the same people take these advisory locks in one sorted
  -- order (no deadlock), so the later one sees the earlier one's Busy blocks; locking this
  -- proposal's holds makes a concurrent hold edit finish first, so coverage reads the edited ranges.
  perform pg_advisory_xact_lock(hashtextextended('friendcal.busy:' || r::text, 0))
     from unnest(v_recipients) as r order by r;
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
    raise exception 'need % percent free, only % percent', round(c_quorum * 100), round(v_free * 100.0 / v_total) using errcode = '22023';
  end if;

  update proposals set status = 'locked', locked_date = p_start, locked_end = p_end where id = p_id;
  delete from availability_slots where source_proposal_id = p_id and state = 'softHold';
  begin
    return query
      insert into busy_blocks (user_id, range, visibility)
      select u, v_window, 'public' from unnest(v_covering) as u
      returning *;
  exception when exclusion_violation then
    -- A recipient added their own Busy block mid-lock (they take no advisory lock). Refuse without
    -- echoing the constraint's DETAIL, which would show that person's busy range to the caller.
    raise exception 'availability changed while locking; try again' using errcode = '40001';
  end;
end;
$$;
-- Supabase's default privileges grant execute to anon directly, so revoking from public is not enough.
revoke all on function lock_proposal(uuid, timestamptz, timestamptz) from public, anon;
grant execute on function lock_proposal(uuid, timestamptz, timestamptz) to authenticated;
