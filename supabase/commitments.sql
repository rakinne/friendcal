-- "My commitments": the one read that tells you what you are on the hook for, and which plan put
-- you there. Idempotent: run after the other wave files on a new project, or on its own to upgrade
-- an existing one. Safe to re-run.
--
-- This RPC exists because the client cannot assemble the answer itself. busy_blocks.source_proposal_id
-- is revoked from `authenticated` (rls.sql section 8) -- it is a correlation key that joins two
-- people's blocks to one plan -- so provenance has to come from a server function. And the plan's
-- TITLE lives on a table whose rows are scoped, so the title has to be authorized, not just fetched.
--
-- ===========================================================================
-- THE TRAP THIS FILE IS BUILT AROUND (CEO review C2).
--
-- A `security definer` function runs as the table owner, and the owner bypasses RLS. So a definer
-- function that simply joins `proposals` to get a title returns titles for EVERY plan, including
-- plans the caller must not see -- the very rows the select policy was written to withhold. The
-- definer context does not merely fail to help here; it actively removes the protection. A Busy
-- block the caller legitimately holds becomes an oracle for the name of a plan they were excluded
-- from, which is exactly the surprise the stealth design exists to keep.
--
-- So the read predicate is RE-APPLIED explicitly, inside the function. And to make sure the
-- re-applied copy can never drift from the policy it mirrors, BOTH call the same predicate
-- function -- there is no second copy to forget. Two hand-maintained predicates that must agree is
-- the same hand-synced-list failure the review named the wave's worst structural risk.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1) The shared read predicate lives in rls.sql, next to the policy that is its other caller.
--    proposal_is_readable(hidden_from, created_by, distribution) is defined there precisely once;
--    this file USES it rather than restating it, and the self-check at the bottom fails if either
--    side stops going through it. Defining the policy in two files would also mean two `create
--    policy` statements for one policy, which is how the harness's policy count caught this.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 2) The row type. Narrow and named, for the same reason lock_proposal returns busy_block_public:
--    a function's return value is not column-privilege checked, so returning a table row type would
--    hand back hidden_from and event_id and undo the column grants.
-- ---------------------------------------------------------------------------
do $$ begin
  create type commitment_row as (
    id uuid,
    kind text,              -- 'held' | 'locked' | 'busy'
    range_start timestamptz,
    range_end timestamptz,
    source_proposal_id uuid,
    plan_title text,        -- NULL when the caller may not read the plan behind this commitment
    expires_at timestamptz
  );
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- 3) my_commitments(p_from): everything you are on the hook for, at or after p_from.
--
--    Inclusion is OVERLAP-based, not start-based (outside voice F8a). `lower(range) >= p_from` would
--    drop a commitment that began before the horizon and is happening RIGHT NOW -- an overnight
--    block, or simply something that started an hour ago. The test for "am I busy now?" is
--    `upper(range) > p_from`, and getting this backwards is invisible except at a day boundary.
--
--    Three kinds, which are the three words the UI shows:
--      held   -- your unexpired softHold on a plan still being decided
--      locked -- a Busy block a locked plan created (it has provenance)
--      busy   -- a Busy block you made yourself (no provenance)
-- ---------------------------------------------------------------------------
create or replace function my_commitments(p_from timestamptz default now())
returns setof commitment_row
language sql
stable
security definer
set search_path = public
as $$
  select
    s.id,
    'held'::text,
    lower(s.range),
    upper(s.range),
    s.source_proposal_id,
    -- The re-applied predicate. Without this, the definer context would return every title.
    case when p.id is not null
          and proposal_is_readable(p.hidden_from, p.created_by, p.distribution)
         then p.title end,
    s.expires_at
  from availability_slots s
  left join proposals p on p.id = s.source_proposal_id
  where s.user_id = auth.uid()
    and s.state = 'softHold'
    and upper(s.range) > p_from
    -- An expired hold is not a commitment. A hold with no expiry never expires, so it still counts.
    and (s.expires_at is null or s.expires_at > now())

  union all

  select
    b.id,
    case when b.source_proposal_id is null then 'busy' else 'locked' end,
    lower(b.range),
    upper(b.range),
    b.source_proposal_id,
    case when p.id is not null
          and proposal_is_readable(p.hidden_from, p.created_by, p.distribution)
         then p.title end,
    null::timestamptz
  from busy_blocks b
  left join proposals p on p.id = b.source_proposal_id
  where b.user_id = auth.uid()
    and upper(b.range) > p_from
$$;
revoke all on function my_commitments(timestamptz) from public, anon;
grant execute on function my_commitments(timestamptz) to authenticated;

-- ---------------------------------------------------------------------------
-- 4) Self-check.
-- ---------------------------------------------------------------------------
do $$
begin
  -- The whole point of C2: the definer function must not be trusting its own privileges for titles.
  if (select prosrc not like '%proposal_is_readable%' from pg_proc where proname = 'my_commitments') then
    raise exception 'commitments.sql: my_commitments() does not re-apply the proposals read predicate, so its definer context would leak every plan title';
  end if;
  -- The policy side of the same invariant. pg_policy has no prosrc; the expression comes back
  -- through pg_get_expr, and if the policy stops using the shared predicate then the policy and the
  -- RPC have two definitions of "readable" again, which is the drift this file exists to prevent.
  if not exists (
    select 1 from pg_policy
     where polname = 'proposals_read_involved'
       and pg_get_expr(polqual, polrelid) like '%proposal_is_readable%') then
    raise exception 'commitments.sql: the proposals read policy no longer uses proposal_is_readable, so it can drift from my_commitments';
  end if;
  if exists (select 1 from information_schema.attributes
              where udt_name = 'commitment_row'
                and attribute_name in ('hidden_from', 'event_id', 'visibility')) then
    raise exception 'commitments.sql: commitment_row exposes a correlation column';
  end if;
  raise notice 'commitments.sql: shared read predicate and my_commitments() verified';
end $$;
