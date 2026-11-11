-- Add a friend: one personal link per person, one tap to connect, friendships on the server.
-- Idempotent: run after schema.sql + schema_additions.sql + lock_proposal.sql + rls.sql +
-- users_auth.sql + join_proposal.sql + commitments.sql + places.sql + social.sql on a new project, or
-- on its own to upgrade an existing one. Safe to re-run. Spec: docs/designs/friendcal-add-friend-spec.md.
--
-- WHAT A FRIENDSHIP GRANTS. Each person can read the other's name and avatar (the users policy arm in
-- users_auth.sql) and can poke the other without a shared plan (send_poke in social.sql). Nothing else:
-- no policy on proposals, busy_blocks, proposal_places, place_votes or tag_alongs knows about
-- friendships, and hidden_from outranks one.
--
-- THE LINK. Each person has one reusable token (friend_links). Whoever opens it may connect with its
-- owner; there is no approval step and no pending row. The token is a bearer secret: it is returned
-- to its owner by friend_link() and reset_friend_link() and to nobody else. Everything that can go
-- wrong with a token -- never issued, reset, owner deleted, the caller removed by the owner, 50
-- accepts reached -- answers the one word `dead`, from preview and accept alike, so a probe learns
-- nothing about which.
--
-- LOCKS. accept, remove and reset take friendcal_lock_users (lock_proposal.sql) on the people involved
-- and then RE-READ what they depend on, so whichever of two racing calls commits second sees the
-- first. send_poke and delete_account take the same lock. Result, in either commit order: an accept
-- that commits before a reset stays connected and one that arrives after answers `dead`; a friendship
-- never survives beside a deleted account; a poke never follows a removal.
--
-- Every function here is definer, takes no user parameter (the caller is auth.uid()), refuses a caller
-- with no active users row, and is executable by `authenticated` alone.

-- ---------------------------------------------------------------------------
-- 1) friendcal_new_friend_token(): 22 base64url characters from ONE gen_random_uuid() value --
--    122 random bits, and no extension needed. 16 bytes encode to 24 base64 characters, the last two
--    being `=` padding, which is stripped. Internal: never callable by a client.
-- ---------------------------------------------------------------------------
create or replace function friendcal_new_friend_token() returns text
language sql
volatile
as $$
  select translate(rtrim(encode(decode(replace(gen_random_uuid()::text, '-', ''), 'hex'), 'base64'), '='), '+/', '-_')
$$;
revoke all on function friendcal_new_friend_token() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2) friendcal_friend_link_answer(token, caller): what would opening this link do, for this caller?
--
--    Returns one row: the answer (`valid`, `own`, `already` or `dead`) and the inviter's id. The
--    inviter is null for `dead`, so a dead answer carries nothing. Internal and read-only; preview
--    and accept both call it, accept again after taking the locks. The order of the tests is the
--    spec's: an unusable token, then the caller's own link, then a removal, then a friendship, then
--    the cap.
-- ---------------------------------------------------------------------------
create or replace function friendcal_friend_link_answer(p_token text, p_caller uuid)
returns table (answer text, inviter uuid)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  c_cap constant int := 50;
  v_link friend_links%rowtype;
begin
  if p_token is null or p_token !~ '^[A-Za-z0-9_-]{22}$' then
    return query select 'dead'::text, null::uuid;
    return;
  end if;
  select * into v_link from friend_links l where l.token = p_token;
  -- A deleted owner's link row is deleted with the account; is_active covers the moment between.
  if not found or not is_active(v_link.user_id) then
    return query select 'dead'::text, null::uuid;
    return;
  end if;
  if v_link.user_id = p_caller then
    return query select 'own'::text, v_link.user_id;
    return;
  end if;
  if exists (select 1 from friend_removals r where r.remover = v_link.user_id and r.removed = p_caller) then
    return query select 'dead'::text, null::uuid;
    return;
  end if;
  if exists (select 1 from friendships f
              where f.user_a = least(p_caller, v_link.user_id) and f.user_b = greatest(p_caller, v_link.user_id)) then
    return query select 'already'::text, v_link.user_id;
    return;
  end if;
  if v_link.token_accepts >= c_cap then
    return query select 'dead'::text, null::uuid;
    return;
  end if;
  return query select 'valid'::text, v_link.user_id;
end $$;
revoke all on function friendcal_friend_link_answer(text, uuid) from public, anon, authenticated;

-- The wire shape of an answer: the status, plus who the inviter is for `valid` and `already` (the
-- Accept screen names them from this, never from the URL's hint). `own` and `dead` carry no one.
create or replace function friendcal_friend_link_json(p_answer text, p_inviter uuid) returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select case
    when p_answer in ('valid', 'already') then
      (select jsonb_build_object('status', p_answer, 'user_id', u.id,
                                 'display_name', u.display_name, 'avatar_url', u.avatar_url)
         from users u where u.id = p_inviter)
    else jsonb_build_object('status', p_answer)
  end
$$;
revoke all on function friendcal_friend_link_json(text, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3) friend_link(): the caller's link, minted only when they have none.
-- ---------------------------------------------------------------------------
create or replace function friend_link() returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_token text;
begin
  if v_uid is null then
    raise exception 'not signed in' using errcode = '42501', hint = 'FC_NOT_SIGNED_IN';
  end if;
  if not is_active(v_uid) then
    raise exception 'this account has been deleted' using errcode = '42501', hint = 'FC_ACCOUNT_DELETED';
  end if;

  -- Two first opens at once (two devices, a double tap) take the lock in turn; the second finds the
  -- first's row. Without it both would mint, and one would fail on the primary key.
  perform friendcal_lock_users(array[v_uid]);
  select l.token into v_token from friend_links l where l.user_id = v_uid;
  if v_token is null then
    insert into friend_links (user_id, token) values (v_uid, friendcal_new_friend_token())
    returning token into v_token;
  end if;
  return jsonb_build_object('token', v_token);
end $$;
revoke all on function friend_link() from public, anon;
grant execute on function friend_link() to authenticated;

-- ---------------------------------------------------------------------------
-- 4) reset_friend_link(): a new token. The old one is dead from the moment this commits. Friends
--    already connected stay connected; the 50-accept count starts over.
-- ---------------------------------------------------------------------------
create or replace function reset_friend_link() returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_token text;
begin
  if v_uid is null then
    raise exception 'not signed in' using errcode = '42501', hint = 'FC_NOT_SIGNED_IN';
  end if;
  if not is_active(v_uid) then
    raise exception 'this account has been deleted' using errcode = '42501', hint = 'FC_ACCOUNT_DELETED';
  end if;

  perform friendcal_lock_users(array[v_uid]);
  update friend_links
     set token = friendcal_new_friend_token(), token_accepts = 0, mint_count = mint_count + 1
   where user_id = v_uid
  returning token into v_token;
  if v_token is null then
    -- Resetting before ever opening the sheet mints the first link, as friend_link() would.
    insert into friend_links (user_id, token) values (v_uid, friendcal_new_friend_token())
    returning token into v_token;
  end if;
  return jsonb_build_object('token', v_token);
end $$;
revoke all on function reset_friend_link() from public, anon;
grant execute on function reset_friend_link() to authenticated;

-- ---------------------------------------------------------------------------
-- 5) preview_friend_link(token): what the Accept screen shows. Changes nothing.
-- ---------------------------------------------------------------------------
create or replace function preview_friend_link(p_token text) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_answer text;
  v_inviter uuid;
begin
  if v_uid is null then
    raise exception 'not signed in' using errcode = '42501', hint = 'FC_NOT_SIGNED_IN';
  end if;
  if not is_active(v_uid) then
    raise exception 'this account has been deleted' using errcode = '42501', hint = 'FC_ACCOUNT_DELETED';
  end if;
  select a.answer, a.inviter into v_answer, v_inviter from friendcal_friend_link_answer(p_token, v_uid) a;
  return friendcal_friend_link_json(v_answer, v_inviter);
end $$;
revoke all on function preview_friend_link(text) from public, anon;
grant execute on function preview_friend_link(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 6) accept_friend_link(token): connect. The same four answers as preview.
--
--    IDEMPOTENT. A double tap, a retry after a lost reply and two people accepting each other's links
--    all end with one friendship row: the locks run the second call after the first, which then reads
--    `already` and changes nothing -- no counter, no second push.
--
--    On `valid`: the friendship goes in, the counters move, a removal record the caller holds against
--    the inviter is cleared (accepting their link is how a remover reconnects), and one push is
--    written to the inviter. The app does not handle `friend_joined` yet; that belongs to the push
--    forwarder work.
-- ---------------------------------------------------------------------------
create or replace function accept_friend_link(p_token text) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_answer text;
  v_inviter uuid;
  v_name text;
begin
  if v_uid is null then
    raise exception 'not signed in' using errcode = '42501', hint = 'FC_NOT_SIGNED_IN';
  end if;
  if not is_active(v_uid) then
    raise exception 'this account has been deleted' using errcode = '42501', hint = 'FC_ACCOUNT_DELETED';
  end if;

  -- First read, unlocked, only to learn whom to lock. A token nobody owns needs no lock at all.
  select a.answer, a.inviter into v_answer, v_inviter from friendcal_friend_link_answer(p_token, v_uid) a;
  if v_inviter is null then
    return friendcal_friend_link_json(v_answer, v_inviter);
  end if;

  perform friendcal_lock_users(array[v_uid, v_inviter]);
  -- Then everything again, now that no reset, removal, deletion or other accept can interleave. Each
  -- statement below runs on a fresh snapshot, so this sees whatever committed while the lock waited.
  select a.answer, a.inviter into v_answer, v_inviter from friendcal_friend_link_answer(p_token, v_uid) a;
  if v_answer is distinct from 'valid' then
    return friendcal_friend_link_json(v_answer, v_inviter);
  end if;

  insert into friendships (user_a, user_b)
  values (least(v_uid, v_inviter), greatest(v_uid, v_inviter));
  update friend_links
     set token_accepts = token_accepts + 1, accept_count = accept_count + 1, last_accepted_at = now()
   where user_id = v_inviter;
  delete from friend_removals where remover = v_uid and removed = v_inviter;

  select u.display_name into v_name from users u where u.id = v_uid;
  insert into push_outbox (recipient_id, kind, title, body, data, expires_at)
  values (
    v_inviter, 'friend_joined',
    coalesce(nullif(btrim(v_name), ''), 'A friend') || ' connected with you',
    'You two are connected.',
    jsonb_build_object('kind', 'friend_joined', 'user_id', v_uid),
    now() + interval '24 hours');

  return friendcal_friend_link_json('valid', v_inviter);
end $$;
revoke all on function accept_friend_link(text) from public, anon;
grant execute on function accept_friend_link(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 7) remove_friend(p_user): end a friendship. Idempotent, and the other person is told nothing.
--
--    A removal record is written only if a friendship was actually deleted, which is what keeps two
--    people from ever holding records against each other. The removed person then reads the
--    remover's links as `dead`, before and after a reset; the remover can reconnect by accepting the
--    other person's link. Pokes already sent stay in the inbox.
-- ---------------------------------------------------------------------------
create or replace function remove_friend(p_user uuid) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_deleted int;
begin
  if v_uid is null then
    raise exception 'not signed in' using errcode = '42501', hint = 'FC_NOT_SIGNED_IN';
  end if;
  if not is_active(v_uid) then
    raise exception 'this account has been deleted' using errcode = '42501', hint = 'FC_ACCOUNT_DELETED';
  end if;
  if p_user is null or p_user = v_uid then
    return jsonb_build_object('removed', false);
  end if;

  perform friendcal_lock_users(array[v_uid, p_user]);
  with d as (
    delete from friendships f
     where f.user_a = least(v_uid, p_user) and f.user_b = greatest(v_uid, p_user)
     returning 1
  ) select count(*) into v_deleted from d;
  if v_deleted > 0 then
    insert into friend_removals (remover, removed) values (v_uid, p_user)
    on conflict (remover, removed) do nothing;
  end if;
  return jsonb_build_object('removed', v_deleted > 0);
end $$;
revoke all on function remove_friend(uuid) from public, anon;
grant execute on function remove_friend(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 8) my_friends(): the caller's friends, newest first. Never a deleted account.
-- ---------------------------------------------------------------------------
create or replace function my_friends()
returns table (id uuid, display_name text, avatar_url text, connected_at timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not signed in' using errcode = '42501', hint = 'FC_NOT_SIGNED_IN';
  end if;
  if not is_active(v_uid) then
    raise exception 'this account has been deleted' using errcode = '42501', hint = 'FC_ACCOUNT_DELETED';
  end if;
  return query
    select u.id, u.display_name, u.avatar_url, f.created_at
      from friendships f
      join users u on u.id = case when f.user_a = v_uid then f.user_b else f.user_a end
     where (f.user_a = v_uid or f.user_b = v_uid)
       and u.deleted_at is null
     order by f.created_at desc, u.id;
end $$;
revoke all on function my_friends() from public, anon;
grant execute on function my_friends() to authenticated;

-- ---------------------------------------------------------------------------
-- 9) Self-check. Fails loudly if the boundary this file exists to hold has moved. A function rather
--    than a bare block so a test can break the boundary on purpose and watch it fail (the same
--    construction as friendcal_blanket_policies in rls.sql); it is run once, below, on every load.
-- ---------------------------------------------------------------------------
create or replace function friendcal_friends_selfcheck() returns void
language plpgsql
as $$
declare
  v_bad text;
  v_fn text;
begin
  select string_agg(c.relname, ', ') into v_bad
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'
     and c.relname in ('friendships', 'friend_links', 'friend_removals')
     and not c.relrowsecurity;
  if v_bad is not null then
    raise exception 'friends.sql: row level security is off on %', v_bad;
  end if;

  -- No client reads or writes these tables, and there is no policy that would let one.
  select string_agg(table_name || '.' || privilege_type, ', ' order by table_name, privilege_type) into v_bad
    from information_schema.table_privileges
   where grantee in ('authenticated', 'anon') and table_schema = 'public'
     and table_name in ('friendships', 'friend_links', 'friend_removals');
  if v_bad is not null then
    raise exception 'friends.sql: a client role holds privileges on a friend table: %', v_bad;
  end if;
  -- table_privileges lists table-level grants only; a column-level grant lives here.
  select string_agg(distinct table_name || '.' || column_name || ' ' || privilege_type, ', ') into v_bad
    from information_schema.column_privileges
   where grantee in ('authenticated', 'anon') and table_schema = 'public'
     and table_name in ('friendships', 'friend_links', 'friend_removals');
  if v_bad is not null then
    raise exception 'friends.sql: a client role holds a column privilege on a friend table: %', v_bad;
  end if;
  select string_agg(tablename, ', ') into v_bad
    from pg_policies
   where schemaname = 'public' and tablename in ('friendships', 'friend_links', 'friend_removals');
  if v_bad is not null then
    raise exception 'friends.sql: a client policy exists on %', v_bad;
  end if;

  -- anon must never reach a friend function; the client ones are authenticated-only, the helpers
  -- belong to no client at all.
  foreach v_fn in array array['friend_link()', 'reset_friend_link()', 'preview_friend_link(text)',
                              'accept_friend_link(text)', 'remove_friend(uuid)', 'my_friends()',
                              'friendcal_is_friend(uuid)'] loop
    if has_function_privilege('anon', v_fn, 'EXECUTE') or has_function_privilege('public', v_fn, 'EXECUTE') then
      raise exception 'friends.sql: anon or public can execute %', v_fn;
    end if;
    if not has_function_privilege('authenticated', v_fn, 'EXECUTE') then
      raise exception 'friends.sql: authenticated cannot execute %', v_fn;
    end if;
  end loop;
  foreach v_fn in array array['friendcal_new_friend_token()', 'friendcal_friend_link_answer(text, uuid)',
                              'friendcal_friend_link_json(text, uuid)'] loop
    if has_function_privilege('anon', v_fn, 'EXECUTE') or has_function_privilege('authenticated', v_fn, 'EXECUTE')
       or has_function_privilege('public', v_fn, 'EXECUTE') then
      raise exception 'friends.sql: a client role can execute the internal helper %', v_fn;
    end if;
  end loop;
end $$;
revoke all on function friendcal_friends_selfcheck() from public, anon, authenticated;

do $$ begin
  perform friendcal_friends_selfcheck();
  raise notice 'friends.sql: friend tables, link functions and grants verified';
end $$;
