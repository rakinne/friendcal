-- Poke and Tag along: the tables, the rules and the push outbox.
-- Idempotent: run after schema.sql + schema_additions.sql + lock_proposal.sql + rls.sql +
-- users_auth.sql + join_proposal.sql + commitments.sql + places.sql on a new project, or on its own
-- to upgrade an existing one. Safe to re-run.
--
-- THE POKE STATE MACHINE. A poke is one row and its state is derived, never stored:
--
--     send_poke ──> live ──ack_poke (push tap, in app)──────────> acknowledged
--                    │   ──send_poke the other way (poke back)──> acknowledged
--                    └───── one hour passes ────────────────────> expired
--
--   acknowledged = acknowledged_at is not null
--   expired      = acknowledged_at is null and expires_at <= now()
--   live         = neither
--
-- One live poke per (from, to) at a time. Sending again while one is live returns that poke with
-- is_new = false and writes no second push, so a double tap, a retry after a dropped response and
-- the same friend poked from two screens all converge on one poke. That is the whole rate limit:
-- an ignored poke costs the recipient one push an hour per friend, and a recipient who answers has
-- chosen to keep playing. (It replaces "1 per (from, to, proposal) per 24h", docs/DECISIONS.md.)
--
-- WHO CAN POKE WHOM. There is no friends table yet, so the graph is the one users_auth.sql already
-- uses for reading a name: two people who share a plan neither is hidden from. Everything else --
-- a stranger, a made-up id, a deleted account -- gets the same FC_NOT_FRIEND, so the RPC cannot be
-- used to test whether an id exists.
--
-- TAG ALONG. Joining a plan after it locked. The caller becomes a recipient and an attendee, gets
-- the same window-sized Busy block lock_proposal() gives everyone else, and the host is told.
-- Exclusion (D12) outranks everything, exactly as in join_proposal(): a hidden id holding the link
-- gets the byte-identical "no such plan".
--
-- PUSH. Every notification is composed HERE, in the transaction that caused it, and written to
-- push_outbox. The Edge Function (supabase/functions/push-notify) only forwards rows to APNs. That
-- is deliberate: the words are chosen where hidden_from is readable and the read predicate is one
-- call away, so the function never has to re-derive who may learn a plan's name (rls.sql's closing
-- note). A poke names a plan only when the recipient can read that plan.

-- ---------------------------------------------------------------------------
-- 1) Tables.
-- ---------------------------------------------------------------------------
create table if not exists pokes (
  id uuid primary key default gen_random_uuid(),
  from_user uuid not null references users(id),
  to_user uuid not null references users(id),
  -- What the poke is about, when it is about a plan both people can read. `set null`, so removing
  -- a plan leaves the poke standing as a plain one.
  proposal_id uuid references proposals(id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  acknowledged_at timestamptz,
  ack_via text,
  constraint pokes_not_self check (from_user <> to_user),
  constraint pokes_expiry_after_creation check (expires_at > created_at),
  constraint pokes_ack_via_known check (ack_via is null or ack_via in ('push', 'app', 'poke_back')),
  -- Acknowledged means both columns, never one: "seen, but we do not know how" is not a state.
  constraint pokes_ack_all_or_none check ((acknowledged_at is null) = (ack_via is null))
);
create index if not exists pokes_by_recipient on pokes (to_user, created_at desc);
create index if not exists pokes_by_sender on pokes (from_user, created_at desc);

-- Who joined a locked plan after the lock, and when. The attendee list on the plan says they are in;
-- this says how they got in, and its created_at is what orders the host's inbox.
create table if not exists tag_alongs (
  proposal_id uuid not null references proposals(id) on delete cascade,
  user_id uuid not null references users(id),
  created_at timestamptz not null default now(),
  primary key (proposal_id, user_id)
);
create index if not exists tag_alongs_recent on tag_alongs (created_at desc);

-- One row per installed app. The token is the key: a phone handed to another account moves its
-- token to that account instead of leaving the old owner's pushes arriving on it.
create table if not exists device_tokens (
  token text primary key,
  user_id uuid not null references users(id) on delete cascade,
  environment text not null default 'production',
  updated_at timestamptz not null default now(),
  constraint device_tokens_hex check (token ~ '^[0-9a-f]{32,200}$'),
  constraint device_tokens_environment check (environment in ('sandbox', 'production'))
);
create index if not exists device_tokens_by_user on device_tokens (user_id);

-- What the Edge Function sends. `data` rides along as the payload's `fc` object so a tap can be
-- routed; `expires_at` becomes apns-expiration, so a poke nobody's phone received inside its hour is
-- dropped by Apple rather than arriving after it has already faded.
create table if not exists push_outbox (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references users(id) on delete cascade,
  kind text not null,
  title text not null,
  body text not null,
  data jsonb not null default '{}',
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  attempts int not null default 0,
  last_error text,
  constraint push_outbox_kind check (kind in ('poke', 'tag_along'))
);
create index if not exists push_outbox_unsent on push_outbox (created_at) where sent_at is null;

-- ---------------------------------------------------------------------------
-- 2) Row security and privileges. One `revoke all`, then exactly what a client may do (rls.sql
--    section 8 explains why the order matters). No client writes any of these tables: every write
--    goes through a function below.
--
--    pokes: the two people on it, nobody else.
--    tag_alongs: whoever can read the plan. The `exists` reads proposals AS THE CALLER, so
--      proposals_read_involved and its hidden_from test apply (the places technique, rls.sql 8b).
--    device_tokens, push_outbox: RLS on and NO policy, so no client reads a token or a queued push.
-- ---------------------------------------------------------------------------
alter table pokes enable row level security;
alter table tag_alongs enable row level security;
alter table device_tokens enable row level security;
alter table push_outbox enable row level security;

revoke all on pokes, tag_alongs, device_tokens, push_outbox from authenticated, anon;
grant select on pokes, tag_alongs to authenticated;

drop policy if exists "pokes_read_own" on pokes;
create policy "pokes_read_own" on pokes for select to authenticated
  using (from_user = auth.uid() or to_user = auth.uid());

drop policy if exists "tag_alongs_read_involved" on tag_alongs;
create policy "tag_alongs_read_involved" on tag_alongs for select to authenticated
  using (exists (select 1 from proposals p where p.id = tag_alongs.proposal_id));

-- ---------------------------------------------------------------------------
-- 3) friendcal_share_plan(a, b): do these two share a plan neither is hidden from?
--
--    Internal: revoked from every client role, called only from the definer functions below. It
--    reads hidden_from, which no client may, so it must never become callable directly -- as a
--    client-callable predicate it would answer "is b hidden from a plan a is on?" by elimination.
--    Cancelled plans do not count: a plan that never happened is not a tie between two people.
-- ---------------------------------------------------------------------------
create or replace function friendcal_share_plan(p_a uuid, p_b uuid) returns boolean
language sql
stable
as $$
  select exists (
    select 1 from proposals p
     where p.status <> 'cancelled'
       and not (p_a = any (coalesce(p.hidden_from, '{}'::uuid[])))
       and not (p_b = any (coalesce(p.hidden_from, '{}'::uuid[])))
       and (p.created_by = p_a or (coalesce(p.distribution, '{}'::jsonb) -> 'recipientIDs') ? p_a::text)
       and (p.created_by = p_b or (coalesce(p.distribution, '{}'::jsonb) -> 'recipientIDs') ? p_b::text))
$$;
revoke all on function friendcal_share_plan(uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4) send_poke(p_to, p_proposal): poke a friend, optionally about a plan.
--
--    Returns the poke as jsonb plus `is_new`. A narrow, named set of keys rather than the row type,
--    for the reason lock_proposal returns busy_block_public: a column added to pokes later must not
--    reach the wire by accident.
--
--    The plan is CONTEXT, never authorization. If either person cannot read p_proposal the poke
--    still goes, with no plan attached. Refusing instead would tell a sender who can read the plan
--    that the recipient was left out of it, which is hidden_from leaking one bit at a time.
-- ---------------------------------------------------------------------------
create or replace function send_poke(p_to uuid, p_proposal uuid default null) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  c_lifetime constant interval := interval '1 hour'; -- matches Poke.lifetime
  v_uid uuid := auth.uid();
  v_poke pokes%rowtype;
  v_plan proposals%rowtype;
  v_plan_id uuid;
  v_plan_title text;
  v_name text;
begin
  if v_uid is null then
    raise exception 'not signed in' using errcode = '42501', hint = 'FC_NOT_SIGNED_IN';
  end if;
  if not is_active(v_uid) then
    raise exception 'this account has been deleted' using errcode = '42501', hint = 'FC_ACCOUNT_DELETED';
  end if;
  if p_to is null or p_to = v_uid then
    raise exception 'you cannot poke yourself' using errcode = '22023', hint = 'FC_SELF_POKE';
  end if;
  -- One refusal for "no such person", "deleted" and "not someone you share a plan with".
  if not is_active(p_to) or not friendcal_share_plan(v_uid, p_to) then
    raise exception 'you can only poke friends you share a plan with'
      using errcode = 'P0002', hint = 'FC_NOT_FRIEND';
  end if;

  -- Serialize both people through the one shared protocol (lock_proposal.sql): the helper sorts the
  -- ids, so two people poking each other at once take the same locks in the same order, run one
  -- after the other, and the second sees the first's poke and answers it.
  perform friendcal_lock_users(array[v_uid, p_to]);

  select * into v_poke from pokes
   where from_user = v_uid and to_user = p_to
     and acknowledged_at is null and expires_at > now()
   order by created_at desc
   limit 1;
  if found then
    return jsonb_build_object(
      'id', v_poke.id, 'from_user', v_poke.from_user, 'to_user', v_poke.to_user,
      'proposal_id', v_poke.proposal_id, 'created_at', v_poke.created_at, 'expires_at', v_poke.expires_at,
      'acknowledged_at', v_poke.acknowledged_at, 'ack_via', v_poke.ack_via, 'is_new', false);
  end if;

  if p_proposal is not null then
    select * into v_plan from proposals p
     where p.id = p_proposal
       and p.status <> 'cancelled'
       and not (v_uid = any (coalesce(p.hidden_from, '{}'::uuid[])))
       and not (p_to = any (coalesce(p.hidden_from, '{}'::uuid[])))
       and (p.created_by = v_uid or (coalesce(p.distribution, '{}'::jsonb) -> 'recipientIDs') ? v_uid::text)
       and (p.created_by = p_to or (coalesce(p.distribution, '{}'::jsonb) -> 'recipientIDs') ? p_to::text);
    if found then
      v_plan_id := v_plan.id;
      v_plan_title := v_plan.title;
    end if;
  end if;

  -- Poking back answers theirs. Same statement for every screen, because it lives here.
  update pokes
     set acknowledged_at = now(), ack_via = 'poke_back'
   where from_user = p_to and to_user = v_uid
     and acknowledged_at is null and expires_at > now();

  insert into pokes (from_user, to_user, proposal_id, expires_at)
  values (v_uid, p_to, v_plan_id, now() + c_lifetime)
  returning * into v_poke;

  select u.display_name into v_name from users u where u.id = v_uid;
  insert into push_outbox (recipient_id, kind, title, body, data, expires_at)
  values (
    p_to, 'poke',
    coalesce(nullif(btrim(v_name), ''), 'A friend') || ' poked you',
    case when v_plan_title is null then 'Poke back before it fades in an hour.'
         else 'About ' || v_plan_title || '. Poke back before it fades in an hour.' end,
    jsonb_build_object('kind', 'poke', 'poke_id', v_poke.id, 'from_user', v_uid, 'proposal_id', v_plan_id),
    v_poke.expires_at);

  return jsonb_build_object(
    'id', v_poke.id, 'from_user', v_poke.from_user, 'to_user', v_poke.to_user,
    'proposal_id', v_poke.proposal_id, 'created_at', v_poke.created_at, 'expires_at', v_poke.expires_at,
    'acknowledged_at', v_poke.acknowledged_at, 'ack_via', v_poke.ack_via, 'is_new', true);
end $$;
revoke all on function send_poke(uuid, uuid) from public, anon;
grant execute on function send_poke(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 5) ack_poke(p_id, p_via): the recipient saw it.
--
--    IDEMPOTENT, and a no-op on a poke that already ended. A push can be tapped twice, tapped after
--    the app already acknowledged it, or tapped tomorrow; none of those is an error and none may
--    reopen or re-stamp the poke. A poke that is not the caller's reads exactly like one that does
--    not exist, so ids cannot be probed.
-- ---------------------------------------------------------------------------
create or replace function ack_poke(p_id uuid, p_via text default 'app') returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_poke pokes%rowtype;
begin
  if v_uid is null then
    raise exception 'not signed in' using errcode = '42501', hint = 'FC_NOT_SIGNED_IN';
  end if;
  select * into v_poke from pokes where id = p_id and to_user = v_uid for update;
  if not found then
    raise exception 'no such poke' using errcode = 'P0002', hint = 'FC_POKE_NOT_FOUND';
  end if;
  if v_poke.acknowledged_at is null and v_poke.expires_at > now() then
    update pokes
       set acknowledged_at = now(),
           -- Anything that is not a push tap is the app. 'poke_back' is send_poke's to write.
           ack_via = case when p_via = 'push' then 'push' else 'app' end
     where id = p_id
    returning * into v_poke;
  end if;
  return jsonb_build_object(
    'id', v_poke.id, 'from_user', v_poke.from_user, 'to_user', v_poke.to_user,
    'proposal_id', v_poke.proposal_id, 'created_at', v_poke.created_at, 'expires_at', v_poke.expires_at,
    'acknowledged_at', v_poke.acknowledged_at, 'ack_via', v_poke.ack_via);
end $$;
revoke all on function ack_poke(uuid, text) from public, anon;
grant execute on function ack_poke(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 6) tag_along(p_id): join a plan that already locked, and tell the host.
--
--    Lock order is lock_proposal()'s: the plan row first, the per-user advisory lock second.
--    The Busy block goes in before the plan is touched, so a refusal leaves nothing behind; its
--    exclusion constraint is the check that the caller is actually free then, and the refusal never
--    echoes the constraint's DETAIL (which would print the clashing range).
-- ---------------------------------------------------------------------------
create or replace function tag_along(p_id uuid) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_prop proposals%rowtype;
  v_ids jsonb;
  v_name text;
begin
  if v_uid is null then
    raise exception 'not signed in' using errcode = '42501', hint = 'FC_NOT_SIGNED_IN';
  end if;

  select * into v_prop from proposals where id = p_id for update;

  -- The same single raise as join_proposal(): excluded and nonexistent cannot drift apart.
  if not found or v_uid = any (v_prop.hidden_from) then
    raise exception 'no such plan' using errcode = 'P0002', hint = 'FC_NOT_FOUND';
  end if;
  if not is_active(v_uid) then
    raise exception 'this account has been deleted' using errcode = '42501', hint = 'FC_ACCOUNT_DELETED';
  end if;
  if v_prop.status = 'requesting' then
    raise exception 'this plan is not locked yet' using errcode = '55000', hint = 'FC_NOT_LOCKED';
  end if;
  if v_prop.status <> 'locked' then
    raise exception 'this plan is %, not open to join', v_prop.status
      using errcode = '55000', hint = 'FC_CLOSED';
  end if;
  if v_prop.locked_date is null or v_prop.locked_end is null or v_prop.locked_end <= now() then
    raise exception 'this plan is over' using errcode = '55000', hint = 'FC_PLAN_OVER';
  end if;

  -- Idempotent: already in, by the lock or by an earlier tag along. No second block, no second push.
  if v_uid = any (v_prop.locked_attendee_ids) then
    return jsonb_build_object('id', v_prop.id, 'title', v_prop.title, 'already_in', true);
  end if;

  perform friendcal_lock_users(array[v_uid]);
  begin
    insert into busy_blocks (user_id, range, visibility, source_proposal_id)
    values (v_uid, tstzrange(v_prop.locked_date, v_prop.locked_end, '[)'), 'public', p_id);
  exception when exclusion_violation then
    raise exception 'you are already busy then' using errcode = '23P01', hint = 'FC_BUSY';
  end;

  v_ids := coalesce(v_prop.distribution -> 'recipientIDs', '[]'::jsonb);
  update proposals
     set distribution = case when v_ids ? v_uid::text then distribution
                             else jsonb_set(coalesce(distribution, '{}'::jsonb), '{recipientIDs}',
                                            v_ids || to_jsonb(v_uid::text)) end,
         locked_attendee_ids = locked_attendee_ids || v_uid
   where id = p_id;

  insert into tag_alongs (proposal_id, user_id) values (p_id, v_uid)
  on conflict (proposal_id, user_id) do nothing;

  -- The host hears about it. Not when the host is the one tagging along, and not a departed host.
  if v_prop.created_by is not null and v_prop.created_by <> v_uid and is_active(v_prop.created_by) then
    select u.display_name into v_name from users u where u.id = v_uid;
    insert into push_outbox (recipient_id, kind, title, body, data, expires_at)
    values (
      v_prop.created_by, 'tag_along',
      coalesce(nullif(btrim(v_name), ''), 'A friend') || ' is tagging along',
      'They just joined ' || v_prop.title || '.',
      jsonb_build_object('kind', 'tag_along', 'proposal_id', p_id, 'user_id', v_uid),
      v_prop.locked_end);
  end if;

  return jsonb_build_object('id', v_prop.id, 'title', v_prop.title, 'already_in', false);
end $$;
revoke all on function tag_along(uuid) from public, anon;
grant execute on function tag_along(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 7) Device tokens. No user parameter, like delete_account(): a caller can only ever register or
--    remove a token for themselves, because there is no way to name anyone else.
-- ---------------------------------------------------------------------------
create or replace function register_device(p_token text, p_environment text default 'production') returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_token text := lower(coalesce(p_token, ''));
begin
  if v_uid is null then
    raise exception 'not signed in' using errcode = '42501', hint = 'FC_NOT_SIGNED_IN';
  end if;
  if not is_active(v_uid) then
    raise exception 'this account has been deleted' using errcode = '42501', hint = 'FC_ACCOUNT_DELETED';
  end if;
  if v_token !~ '^[0-9a-f]{32,200}$' or p_environment is null or p_environment not in ('sandbox', 'production') then
    raise exception 'not a device token' using errcode = '22023', hint = 'FC_BAD_TOKEN';
  end if;
  insert into device_tokens (token, user_id, environment)
  values (v_token, v_uid, p_environment)
  on conflict (token) do update
    set user_id = excluded.user_id, environment = excluded.environment, updated_at = now();
end $$;
revoke all on function register_device(text, text) from public, anon;
grant execute on function register_device(text, text) to authenticated;

create or replace function unregister_device(p_token text) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not signed in' using errcode = '42501', hint = 'FC_NOT_SIGNED_IN';
  end if;
  delete from device_tokens where token = lower(coalesce(p_token, '')) and user_id = auth.uid();
end $$;
revoke all on function unregister_device(text) from public, anon;
grant execute on function unregister_device(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 8) A deleted account stops receiving. delete_account() turns the users row into a tombstone
--    instead of deleting it, so `on delete cascade` never fires; this trigger is what clears the
--    departed person's tokens and anything still queued for them. Their pokes stay as history for
--    the other person, and send_poke() already refuses a tombstone as FC_NOT_FRIEND.
-- ---------------------------------------------------------------------------
create or replace function friendcal_purge_push_on_delete() returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from device_tokens where user_id = new.id;
  delete from push_outbox where recipient_id = new.id and sent_at is null;
  return new;
end $$;
revoke all on function friendcal_purge_push_on_delete() from public, anon, authenticated;

drop trigger if exists friendcal_purge_push_on_delete_trg on users;
create trigger friendcal_purge_push_on_delete_trg
  after update of deleted_at on users
  for each row when (new.deleted_at is not null and old.deleted_at is null)
  execute function friendcal_purge_push_on_delete();

-- ---------------------------------------------------------------------------
-- 9) Self-check.
-- ---------------------------------------------------------------------------
do $$
declare
  v_tables text;
begin
  select string_agg(c.relname, ', ') into v_tables
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'
     and c.relname in ('pokes', 'tag_alongs', 'device_tokens', 'push_outbox')
     and not c.relrowsecurity;
  if v_tables is not null then
    raise exception 'social.sql: row level security is off on %', v_tables;
  end if;

  -- No client may write any of these directly, and none may read a token or a queued push at all.
  select string_agg(table_name || '.' || privilege_type, ', ' order by table_name, privilege_type) into v_tables
    from information_schema.table_privileges
   where grantee in ('authenticated', 'anon') and table_schema = 'public'
     and ((table_name in ('pokes', 'tag_alongs') and privilege_type <> 'SELECT')
          or table_name in ('device_tokens', 'push_outbox'));
  if v_tables is not null then
    raise exception 'social.sql: a client role holds privileges it must not: %', v_tables;
  end if;

  if has_function_privilege('authenticated', 'friendcal_share_plan(uuid, uuid)', 'EXECUTE') then
    raise exception 'social.sql: authenticated can call friendcal_share_plan, which answers who is hidden from a plan';
  end if;
  raise notice 'social.sql: poke, tag along and push tables, policies and functions verified';
end $$;
