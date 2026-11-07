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

-- lock_proposal() lives in supabase/lock_proposal.sql: run it after this file on a new project,
-- and on its own to upgrade an existing one (it is idempotent).
