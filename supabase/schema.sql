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
  locked_date timestamptz,
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
