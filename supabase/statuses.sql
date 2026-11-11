-- Friend statuses: what a person says they are doing ("at the movies, no spoilers"), shown to friends.
-- Idempotent: run after schema.sql + the rest of the wave (it needs friends.sql's `friendships`), on a
-- new project or on its own to upgrade an existing one. Safe to re-run.
--
-- A status is something a person sets on purpose. It is never derived from busy_blocks, holds or plans,
-- so nothing here touches the stealth boundary: unlabeled time and every stealth plan still read as the
-- plain grey "busy" in the app.
--
-- WHO SEES IT. Only the owner and the owner's friends (a `friendships` row), and only while it is
-- active (`until` null or in the future). The table has RLS on and NO policy and no client grant: every
-- read and write goes through the definer functions below, which take no user parameter (the caller is
-- auth.uid()), refuse a caller with no active users row, and are executable by `authenticated` alone.
-- One row per person: setting a status replaces the last one.

create table if not exists user_statuses (
  user_id    uuid primary key references users(id) on delete cascade,
  kind       text not null
             check (kind in ('work','movies','concert','gym','cooking','flying','studying','napping','free')),
  message    text not null default '' check (char_length(message) <= 60),
  since      timestamptz not null default now(),
  until      timestamptz,
  check (until is null or until > since)
);
alter table user_statuses enable row level security;
revoke all on table user_statuses from public, anon, authenticated;

-- set_my_status(kind, message, until): replaces the caller's status. `until` null = until they change it.
-- The server stamps `since`; a client clock is never trusted for it. The message is flattened to one
-- line and trimmed here too, so a modified client cannot store what the app would never show.
create or replace function set_my_status(p_kind text, p_message text, p_until timestamptz)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_msg text := left(btrim(regexp_replace(coalesce(p_message, ''), '[\r\n]+', ' ', 'g')), 60);
begin
  if v_uid is null then
    raise exception 'not signed in' using errcode = '42501', hint = 'FC_NOT_SIGNED_IN';
  end if;
  if not is_active(v_uid) then
    raise exception 'this account has been deleted' using errcode = '42501', hint = 'FC_ACCOUNT_DELETED';
  end if;
  if p_until is not null and p_until <= now() then
    raise exception 'a status must end in the future' using errcode = '22023', hint = 'FC_BAD_STATUS';
  end if;
  insert into user_statuses (user_id, kind, message, since, until)
  values (v_uid, p_kind, btrim(v_msg), now(), p_until)
  on conflict (user_id) do update
    set kind = excluded.kind, message = excluded.message, since = excluded.since, until = excluded.until;
end $$;
revoke all on function set_my_status(text, text, timestamptz) from public, anon;
grant execute on function set_my_status(text, text, timestamptz) to authenticated;

-- clear_my_status(): idempotent.
create or replace function clear_my_status()
returns void
language sql
security definer
set search_path = public
as $$
  delete from user_statuses where user_id = auth.uid()
$$;
revoke all on function clear_my_status() from public, anon;
grant execute on function clear_my_status() to authenticated;

-- friend_statuses(): the active statuses of the caller's friends AND the caller's own (so a relaunch
-- shows what they set). Never a deleted account, never a
-- stranger, never an expired status.
create or replace function friend_statuses()
returns table (user_id uuid, kind text, message text, since timestamptz, until timestamptz)
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
    select s.user_id, s.kind, s.message, s.since, s.until
      from user_statuses s
      join users u on u.id = s.user_id and u.deleted_at is null
     where (s.until is null or s.until > now())
       and (s.user_id = v_uid
            or exists (select 1 from friendships f
                        where f.user_a = least(v_uid, s.user_id) and f.user_b = greatest(v_uid, s.user_id)));
end $$;
revoke all on function friend_statuses() from public, anon;
grant execute on function friend_statuses() to authenticated;
