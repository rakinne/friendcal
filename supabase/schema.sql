-- FriendCal Supabase schema — Phase 1 (Approach B, Stealth P0)
-- Run in Supabase SQL editor. Enables RLS invariant: excluded viewer (e.g. Jalen) never receives surprise-brunch payload.

create extension if not exists "pgcrypto";

create table users (
  id uuid primary key default gen_random_uuid(),
  display_name text not null,
  avatar_url text
);

create table proposals (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  window_start timestamptz not null,
  window_end timestamptz not null,
  created_by uuid references users(id),
  distribution jsonb not null default '{}',
  status text not null default 'requesting',
  locked_date timestamptz, -- locked common window start
  locked_end timestamptz,  -- locked common window end (D12)
  created_at timestamptz default now()
);
-- Existing databases created before locked_end:
alter table proposals add column if not exists locked_end timestamptz;

create table availability_slots (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id) not null,
  range tstzrange not null,
  source_proposal_id uuid references proposals(id),
  state text not null default 'free',
  expires_at timestamptz,
  created_at timestamptz default now()
);

create table events (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  date timestamptz not null,
  venue text,
  host_id uuid references users(id),
  attendee_ids uuid[] not null default '{}',
  busy_block_ids uuid[] not null default '{}',
  invite_art_template text default 'partiful-classic',
  created_at timestamptz default now()
);

create table busy_blocks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id) not null,
  range tstzrange not null,
  visibility text not null default 'public',
  hidden_from uuid[] not null default '{}',
  event_id uuid references events(id),
  created_at timestamptz default now()
);

-- Enable RLS
alter table busy_blocks enable row level security;
alter table events enable row level security;
alter table availability_slots enable row level security;
alter table proposals enable row level security;

-- Performance + safety: GiST indexes for range queries + exclusion to prevent double-book on hard Busy
create extension if not exists "btree_gist";
create index if not exists idx_busy_blocks_user_range on busy_blocks using gist (user_id, range);
create index if not exists idx_availability_user_range on availability_slots using gist (user_id, range);
-- Prevent overlapping hard Busy for same user (softHold allowed to overlap, busy not)
-- Note: requires btree_gist; softHold rows can overlap because state != 'busy'
alter table busy_blocks drop constraint if exists no_overlapping_busy;
alter table busy_blocks add constraint no_overlapping_busy
  exclude using gist (user_id with =, range with &&) where (visibility = 'public'::text or visibility = 'stealth'::text);
-- Circles for membership-scoped availability reads (used by RLS above when ready)
create table if not exists circles (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz default now()
);
create table if not exists circle_members (
  circle_id uuid references circles(id) on delete cascade,
  user_id uuid references users(id) on delete cascade,
  primary key (circle_id, user_id)
);

-- Lock a proposal atomically (D3, D12; review D5). The creator picks the common window; the server
-- re-derives who is free instead of trusting the client: a recipient counts when the union of their
-- unexpired softHolds for this proposal covers the window (range_agg merges touching ranges, like
-- HeatmapBuilder.merge) and they have no Busy block over it yet. The quorum is fixed here, never a
-- parameter. One transaction sets status and both ends, inserts one window-sized Busy block per free
-- recipient and clears the proposal's softHolds; any refusal rolls the whole lock back.
-- Tests: supabase/tests/lock_proposal_test.sql (scripts/test-sql.sh).
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
  return query
    insert into busy_blocks (user_id, range, visibility)
    select u, v_window, 'public' from unnest(v_covering) as u
    returning *;
end;
$$;
-- Supabase's default privileges grant execute to anon directly, so revoking from public is not enough.
revoke all on function lock_proposal(uuid, timestamptz, timestamptz) from public, anon;
grant execute on function lock_proposal(uuid, timestamptz, timestamptz) to authenticated;
