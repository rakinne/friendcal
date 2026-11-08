-- Joining a plan from a shared link, and the summary view the invite screen reads.
-- Idempotent: run after schema.sql + schema_additions.sql + rls.sql + users_auth.sql on a new
-- project, or on its own to upgrade an existing one. Safe to re-run.
--
-- WHY THIS RPC EXISTS AT ALL (outside voice F7, the most valuable finding of the review): under
-- D6's row scoping, someone who holds a forwarded link is not yet party to the plan, so they CANNOT
-- READ IT. A client that waits to load the proposal before joining dead-ends forever -- the screen
-- never reaches `.ready`, so it never joins, so it never becomes able to load. The link silently
-- does nothing, and nothing in a single-device test would ever show it.
--
-- So joining must come FIRST, through a security definer RPC that does not require the caller to be
-- able to read the row yet, and it returns the summary the invite screen needs so that "join, then
-- show" is one round trip rather than two.

-- ---------------------------------------------------------------------------
-- 1) proposal_summaries: what a participant may know about a plan.
--
--    security_invoker = true, so proposals' own RLS decides which rows appear. That is what makes
--    D12 exclusion hold here for free: an excluded id is filtered out by the select policy before
--    this view ever runs, so there is no second place to get the exclusion rule wrong.
--    hidden_from is not referenced at all -- the view could not expose it even if the policy
--    changed, and under security_invoker the caller would need privileges on it anyway.
--
--    Counts come only from `distribution`, never from a join against availability_slots. A join
--    would be read through the CALLER's permissions on holds, so a recipient (who may read only
--    their own hold) would see joined_count = 1 while the creator saw the true number. A count that
--    means something different depending on who asks is worse than no count.
-- ---------------------------------------------------------------------------
drop view if exists proposal_summaries;
create view proposal_summaries with (security_invoker = true) as
  select
    p.id,
    p.title,
    p.window_start,
    p.window_end,
    p.created_by,
    p.status,
    p.locked_date,
    p.locked_end,
    p.created_at,
    -- Distinct, because a recipient listed twice is one person (lock_proposal counts them once too).
    (select count(distinct e.value)
       from jsonb_array_elements_text(coalesce(p.distribution -> 'recipientIDs', '[]'::jsonb)) e)::int
      as recipient_count,
    -- What the creator said they were inviting, if they said. Null when unstated.
    nullif(p.distribution ->> 'expectedCount', '')::int as expected_count,
    -- The headline number. A creator who said "about six" and has four joined should still read six;
    -- one who said four and has six joined should read six. Hence greatest(), not either alone.
    greatest(
      coalesce(nullif(p.distribution ->> 'expectedCount', '')::int, 0),
      (select count(distinct e.value)
         from jsonb_array_elements_text(coalesce(p.distribution -> 'recipientIDs', '[]'::jsonb)) e)::int
    ) as attendee_count
  from proposals p;
grant select on proposal_summaries to authenticated;

-- ---------------------------------------------------------------------------
-- 2) join_proposal(): admit the caller, or tell them nothing.
--
--    D12 exclusion precedence: an excluded id that holds the link gets EXACTLY what someone with a
--    made-up link gets -- the same SQLSTATE, the same FC_NOT_FOUND hint, the same message. Not a
--    distinguishable "you are not allowed" refusal, which would itself confirm the plan exists and
--    that somebody deliberately left them out. The refusal must be indistinguishable or the stealth
--    property is decorative: the one person who must not learn about the surprise is precisely the
--    person holding a forwarded link.
--
--    Exclusion is checked BEFORE status, before activity, before everything, so no earlier branch
--    can leak a different error for an excluded id.
-- ---------------------------------------------------------------------------
create or replace function join_proposal(p_id uuid) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_prop proposals%rowtype;
  v_ids jsonb;
  v_already boolean;
begin
  if v_uid is null then
    raise exception 'not signed in' using errcode = '42501', hint = 'FC_NOT_SIGNED_IN';
  end if;

  select * into v_prop from proposals where id = p_id for update;

  -- The two indistinguishable cases, deliberately sharing one raise so they cannot drift apart.
  if not found or v_uid = any (v_prop.hidden_from) then
    raise exception 'no such plan' using errcode = 'P0002', hint = 'FC_NOT_FOUND';
  end if;

  if not is_active(v_uid) then
    raise exception 'this account has been deleted' using errcode = '42501', hint = 'FC_ACCOUNT_DELETED';
  end if;

  v_ids := coalesce(v_prop.distribution -> 'recipientIDs', '[]'::jsonb);
  v_already := v_ids ? v_uid::text;

  if v_prop.status <> 'requesting' and not v_already then
    -- Joining a plan that has already been decided. Someone already party to it may still read it.
    raise exception 'this plan is %, not open to join', v_prop.status
      using errcode = '55000', hint = 'FC_CLOSED';
  end if;

  -- Idempotent: a second tap of the same link is a no-op, not an error and not a duplicate entry.
  -- The UPDATE moves `distribution`, which proposals_edit_guard forbids clients from touching; it
  -- passes here because this function is security definer owned by the table owner, which is the
  -- trusted-mutation signal the guard keys on.
  if not v_already then
    update proposals
       set distribution = jsonb_set(
             coalesce(distribution, '{}'::jsonb),
             '{recipientIDs}',
             v_ids || to_jsonb(v_uid::text))
     where id = p_id;
  end if;

  -- The summary, so "join then show" is one round trip. Safe to return: the caller is a member now.
  return jsonb_build_object(
    'id', v_prop.id,
    'title', v_prop.title,
    'window_start', v_prop.window_start,
    'window_end', v_prop.window_end,
    'status', v_prop.status,
    'locked_date', v_prop.locked_date,
    'locked_end', v_prop.locked_end,
    'already_member', v_already);
end $$;
revoke all on function join_proposal(uuid) from public, anon;
grant execute on function join_proposal(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3) Self-check.
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'proposal_summaries'
       and column_name = 'hidden_from') then
    raise exception 'join_proposal.sql: proposal_summaries exposes hidden_from';
  end if;
  if not exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relname = 'proposal_summaries'
       and c.reloptions @> array['security_invoker=true']) then
    raise exception 'join_proposal.sql: proposal_summaries is not security_invoker, so it would bypass the proposals read policy';
  end if;
  raise notice 'join_proposal.sql: summary view and join RPC verified';
end $$;
