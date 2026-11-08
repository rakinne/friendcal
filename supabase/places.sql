-- Place voting (#10, #11): the server rules for suggesting, voting on, vetoing and withdrawing places.
-- Idempotent: run after schema.sql, schema_additions.sql, lock_proposal.sql, rls.sql and
-- users_auth.sql, or on its own to upgrade an existing database. Safe to re-run.
--
-- lock_proposal() calls friendcal_place_winner() when it runs, so this file must be applied before
-- any plan is locked on a database (see the runbook entry in TODOS.md).
--
-- Structure, grants and policies live elsewhere: the tables in schema_additions.sql, their read
-- policies and the city rules in rls.sql, the lock-time winner in lock_proposal.sql, and vote cleanup
-- in users_auth.sql. This file is the guard, the winner rule, and four client-callable functions.
--
-- Three functions here are INTERNAL and granted to nobody: friendcal_places_plan (the guard) and
-- friendcal_place_winner, plus friendcal_lock_plans in lock_proposal.sql. They are revoked from
-- `authenticated` as well as public and anon. Supabase's default privileges grant EXECUTE on new
-- functions to authenticated, so revoking only public and anon would leave the guard callable, and it
-- returns the whole plan row including hidden_from. friendcal_lock_users revokes authenticated for
-- the same reason. The self-check at the bottom fails the load if any of them is callable.
--
-- Every refusal carries an FC_* hint. The SQLSTATE is the wire contract, the hint is the stable
-- identifier UserFacingError maps to a sentence, and the client never parses the message text.

-- ---------------------------------------------------------------------------
-- The guard. Every client function calls it first, so the exclusion logic exists once.
--
-- Lock order: the caller's own users row `for share`, then the plan row `for update`. delete_account()
-- takes the users row first too (`for no key update`) and the plan rows after it, and lock_proposal()
-- takes the plan row first, so no two of them take two locks in opposite orders. `for share` conflicts
-- with `for no key update`, so a vote and a deletion for the same user still serialize: a vote that
-- races a deletion finishes first and is then deleted, or waits and is refused with
-- FC_ACCOUNT_DELETED.
--
-- Exclusion is tested before anything else, and shares ONE raise with a missing plan (and with a null
-- id), so no earlier branch can leak a different error to the person a plan is hidden from.
-- ---------------------------------------------------------------------------
create or replace function friendcal_places_plan(p_id uuid) returns proposals
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_prop proposals%rowtype;
begin
  if v_uid is null then
    raise exception 'not signed in' using errcode = '42501', hint = 'FC_NOT_SIGNED_IN';
  end if;

  perform 1 from users u where u.id = v_uid for share;
  select * into v_prop from proposals where id = p_id for update;

  -- The two indistinguishable cases, deliberately sharing one raise so they cannot drift apart.
  if not found or v_uid = any (v_prop.hidden_from) then
    raise exception 'no such plan' using errcode = 'P0002', hint = 'FC_NOT_FOUND';
  end if;

  if not is_active(v_uid) then
    raise exception 'this account has been deleted' using errcode = '42501', hint = 'FC_ACCOUNT_DELETED';
  end if;

  -- Exclusion was handled above, so anything but true here means "not a member". The readable rule has
  -- exactly one copy (rls.sql); it reads auth.uid(), which a definer function does not change. It can
  -- return NULL, not just false: a plan whose distribution has no recipient list gives `false or null`.
  -- RLS reads NULL as deny, but `if not null` is not true in plpgsql, so the test must be `is not true`.
  if proposal_is_readable(v_prop.hidden_from, v_prop.created_by, v_prop.distribution) is not true then
    raise exception 'you are not part of this plan' using errcode = '42501', hint = 'FC_NOT_MEMBER';
  end if;

  if v_prop.status = 'locked' then
    raise exception 'this plan is locked' using errcode = '55000', hint = 'FC_LOCKED';
  elsif v_prop.status <> 'requesting' then
    raise exception 'this plan is %', v_prop.status using errcode = '55000', hint = 'FC_CLOSED';
  end if;

  return v_prop;
end $$;
revoke all on function friendcal_places_plan(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- The winner rule (R7), in one place: among non-vetoed places with at least one vote, the most votes;
-- ties go to the earliest suggested, then to the lowest id. The inner join is what enforces "at least
-- one vote". Returns null when nothing qualifies. lock_proposal() stores the result with the status.
-- Mirrored in Swift by PlaceBoard.winner; both read supabase/tests/fixtures/place_winner_cases.json.
-- ---------------------------------------------------------------------------
create or replace function friendcal_place_winner(p_proposal_id uuid) returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select pl.id
    from proposal_places pl
    join place_votes v on v.place_id = pl.id
   where pl.proposal_id = p_proposal_id and pl.vetoed_at is null
   group by pl.id, pl.created_at
   order by count(*) desc, pl.created_at asc, pl.id asc
   limit 1
$$;
revoke all on function friendcal_place_winner(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- suggest_place: add a place to a plan. Idempotent for a duplicate of an active place.
-- ---------------------------------------------------------------------------
create or replace function suggest_place(
  p_proposal_id uuid,
  p_name text,
  p_address text,
  p_lat double precision,
  p_lon double precision,
  p_map_ref text
) returns proposal_places
language plpgsql
security definer
set search_path = public
as $$
declare
  c_per_person constant int := 2;   -- pinned to PlaceBoard.perPersonLimit by a Swift test that reads this file
  c_per_plan   constant int := 10;  -- pinned to PlaceBoard.planLimit by a Swift test that reads this file
  v_uid uuid := auth.uid();
  v_prop proposals%rowtype;
  v_name text := btrim(p_name);
  v_address text := nullif(btrim(p_address), '');
  v_ref text := nullif(btrim(p_map_ref), '');
  v_match proposal_places%rowtype;
  v_row proposal_places%rowtype;
begin
  v_prop := friendcal_places_plan(p_proposal_id);

  if v_prop.area_name is null then
    raise exception 'the host has not picked a city yet' using errcode = 'P0001', hint = 'FC_NO_AREA';
  end if;

  -- Field shape only. Whether the place is real or near the city is not the server's concern.
  -- `not between` is true for NaN and infinity as well, which is what we want.
  if v_name is null or v_name = '' or char_length(v_name) > 120
     or char_length(coalesce(v_address, '')) > 240
     or char_length(coalesce(v_ref, '')) > 200
     or p_lat is null or p_lon is null
     or p_lat not between -90 and 90 or p_lon not between -180 and 180 then
    raise exception 'invalid place' using errcode = '22023', hint = 'FC_BAD_PLACE';
  end if;

  -- A duplicate is the same non-null map reference, or the same name (case-insensitive) with both
  -- coordinates STRICTLY less than 0.001 degrees apart (about 110 m). Exactly 0.001 is not a match.
  -- An active match wins over a vetoed one: the earliest created, then the lowest id.
  select * into v_match
    from proposal_places pl
   where pl.proposal_id = p_proposal_id and pl.vetoed_at is null
     and ((v_ref is not null and pl.map_ref = v_ref)
          or (lower(pl.name) = lower(v_name)
              and abs(pl.lat - p_lat) < 0.001 and abs(pl.lon - p_lon) < 0.001))
   order by pl.created_at, pl.id
   limit 1;
  if found then
    return v_match;
  end if;
  if exists (select 1 from proposal_places pl
              where pl.proposal_id = p_proposal_id and pl.vetoed_at is not null
                and ((v_ref is not null and pl.map_ref = v_ref)
                     or (lower(pl.name) = lower(v_name)
                         and abs(pl.lat - p_lat) < 0.001 and abs(pl.lon - p_lon) < 0.001))) then
    raise exception 'the host passed on that place' using errcode = 'P0001', hint = 'FC_VETOED';
  end if;

  -- The personal cap is checked before the plan cap because it is the more actionable message.
  if (select count(*) from proposal_places pl
       where pl.proposal_id = p_proposal_id and pl.suggested_by = v_uid and pl.vetoed_at is null) >= c_per_person then
    raise exception 'you have suggested % places already', c_per_person
      using errcode = '54000', hint = 'FC_PLACE_LIMIT';
  end if;
  if (select count(*) from proposal_places pl
       where pl.proposal_id = p_proposal_id and pl.vetoed_at is null) >= c_per_plan then
    raise exception 'this plan already has % places', c_per_plan
      using errcode = '54000', hint = 'FC_PLAN_FULL';
  end if;

  -- created_at is read here, after the plan row lock is held: now() is the transaction start, which
  -- could order two suggestions by when their transactions began rather than when they arrived, and
  -- created_at is the tie-break for the earliest-suggested rule.
  insert into proposal_places (proposal_id, suggested_by, name, address, lat, lon, map_ref, created_at)
  values (p_proposal_id, v_uid, v_name, v_address, p_lat, p_lon, v_ref, clock_timestamp())
  returning * into v_row;
  return v_row;
end $$;
revoke all on function suggest_place(uuid, text, text, double precision, double precision, text) from public, anon;
grant execute on function suggest_place(uuid, text, text, double precision, double precision, text) to authenticated;

-- ---------------------------------------------------------------------------
-- vote_place: one vote per person per plan, never for your own suggestion. A null place clears the
-- caller's vote. Moving a vote rewrites its created_at; repeating the same vote changes nothing,
-- because the order of voters on a row depends on it.
-- ---------------------------------------------------------------------------
create or replace function vote_place(p_proposal_id uuid, p_place_id uuid) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_prop proposals%rowtype;
  v_place proposal_places%rowtype;
begin
  v_prop := friendcal_places_plan(p_proposal_id);

  if p_place_id is null then
    delete from place_votes where proposal_id = p_proposal_id and voter_id = v_uid;
    return;
  end if;

  -- The caller is a member by now, so saying the place is not on this plan reveals nothing.
  select * into v_place from proposal_places where id = p_place_id and proposal_id = p_proposal_id;
  if not found then
    raise exception 'that place is not on this plan' using errcode = 'P0002', hint = 'FC_PLACE_NOT_FOUND';
  end if;
  if v_place.vetoed_at is not null then
    raise exception 'the host passed on that place' using errcode = 'P0001', hint = 'FC_VETOED';
  end if;
  if v_place.suggested_by = v_uid then
    raise exception 'you cannot vote for your own suggestion' using errcode = '42501', hint = 'FC_OWN_PLACE';
  end if;

  insert into place_votes (proposal_id, voter_id, place_id, created_at)
  values (p_proposal_id, v_uid, p_place_id, clock_timestamp())
  on conflict (proposal_id, voter_id)
  do update set place_id = excluded.place_id, created_at = excluded.created_at
   where place_votes.place_id <> excluded.place_id;
end $$;
revoke all on function vote_place(uuid, uuid) from public, anon;
grant execute on function vote_place(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- veto_place: the host passes on a place, or brings it back. A veto deletes the votes on that place;
-- bringing it back restores it with zero votes, under the same caps as a new suggestion.
--
-- The place's plan is read WITHOUT a lock so the guard can be called with it. An unknown place id
-- makes that value null, which raises the same FC_NOT_FOUND as a plan the caller is excluded from.
-- That is deliberate: a distinct "place not found" here would let an excluded caller tell a real
-- place id from a fake one.
-- ---------------------------------------------------------------------------
create or replace function veto_place(p_place_id uuid, p_vetoed boolean) returns proposal_places
language plpgsql
security definer
set search_path = public
as $$
declare
  c_per_person constant int := 2;
  c_per_plan   constant int := 10;
  v_prop proposals%rowtype;
  v_place proposal_places%rowtype;
  v_pid uuid;
begin
  select pl.proposal_id into v_pid from proposal_places pl where pl.id = p_place_id;
  v_prop := friendcal_places_plan(v_pid);

  -- Re-read under the plan lock: the place may have been withdrawn while we waited for it.
  select * into v_place from proposal_places where id = p_place_id;
  if not found then
    raise exception 'no such plan' using errcode = 'P0002', hint = 'FC_NOT_FOUND';
  end if;

  if v_prop.created_by is distinct from auth.uid() then
    raise exception 'only the host can pass on a place' using errcode = '42501', hint = 'FC_NOT_CREATOR';
  end if;
  if p_vetoed is null then
    raise exception 'invalid place' using errcode = '22023', hint = 'FC_BAD_PLACE';
  end if;

  if p_vetoed then
    if v_place.vetoed_at is null then
      update proposal_places set vetoed_at = now() where id = p_place_id returning * into v_place;
      delete from place_votes where place_id = p_place_id;
    end if;
  elsif v_place.vetoed_at is not null then
    -- Bring it back as if it were being added now: the caps count active places only.
    if (select count(*) from proposal_places pl
         where pl.proposal_id = v_place.proposal_id and pl.suggested_by = v_place.suggested_by
           and pl.vetoed_at is null) >= c_per_person then
      raise exception 'that friend already has % places', c_per_person
        using errcode = '54000', hint = 'FC_PLACE_LIMIT';
    end if;
    if (select count(*) from proposal_places pl
         where pl.proposal_id = v_place.proposal_id and pl.vetoed_at is null) >= c_per_plan then
      raise exception 'this plan already has % places', c_per_plan
        using errcode = '54000', hint = 'FC_PLAN_FULL';
    end if;
    update proposal_places set vetoed_at = null where id = p_place_id returning * into v_place;
  end if;
  return v_place;
end $$;
revoke all on function veto_place(uuid, boolean) from public, anon;
grant execute on function veto_place(uuid, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- remove_place: the suggester withdraws their own place. Its votes go with it through the cascade.
-- A place the host passed on cannot be withdrawn (FC_VETOED): the veto must outlive the withdrawal.
-- ---------------------------------------------------------------------------
create or replace function remove_place(p_place_id uuid) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_prop proposals%rowtype;
  v_place proposal_places%rowtype;
  v_pid uuid;
begin
  select pl.proposal_id into v_pid from proposal_places pl where pl.id = p_place_id;
  v_prop := friendcal_places_plan(v_pid);

  select * into v_place from proposal_places where id = p_place_id;
  if not found then
    raise exception 'no such plan' using errcode = 'P0002', hint = 'FC_NOT_FOUND';
  end if;
  if v_place.suggested_by <> auth.uid() then
    raise exception 'only the person who suggested a place can remove it'
      using errcode = '42501', hint = 'FC_NOT_YOUR_PLACE';
  end if;
  -- A place the host passed on stays. The vetoed row is what refuses a re-suggestion (suggest_place),
  -- so deleting it would let the same place come back as an active one. The host can bring it back,
  -- after which the suggester can withdraw it.
  if v_place.vetoed_at is not null then
    raise exception 'the host passed on that place' using errcode = 'P0001', hint = 'FC_VETOED';
  end if;
  delete from proposal_places where id = p_place_id;
end $$;
revoke all on function remove_place(uuid) from public, anon;
grant execute on function remove_place(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Self-check. A callable internal function, or a client function open to anon, fails the load rather
-- than installing quietly (in single-transaction mode this rolls the whole file back).
-- ---------------------------------------------------------------------------
do $$
declare
  f text;
begin
  foreach f in array array['friendcal_places_plan(uuid)', 'friendcal_place_winner(uuid)', 'friendcal_lock_plans(uuid[])'] loop
    if has_function_privilege('authenticated', f, 'EXECUTE') or has_function_privilege('anon', f, 'EXECUTE') then
      raise exception 'places.sql: % is callable from a client', f;
    end if;
  end loop;
  foreach f in array array['suggest_place(uuid,text,text,double precision,double precision,text)',
                           'vote_place(uuid,uuid)', 'veto_place(uuid,boolean)', 'remove_place(uuid)'] loop
    if has_function_privilege('anon', f, 'EXECUTE') then
      raise exception 'places.sql: % is callable by anon', f;
    end if;
    if not has_function_privilege('authenticated', f, 'EXECUTE') then
      raise exception 'places.sql: % is not callable by authenticated', f;
    end if;
  end loop;
  raise notice 'places.sql: guard, winner rule and client functions verified';
end $$;
