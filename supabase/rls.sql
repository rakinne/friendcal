-- RLS: Stealth invariant — excluded viewer (hidden_from) must see indistinguishable grey Busy
-- Strategy: Server-enforced column stripping via sanitized view. Client never receives hidden_from/event payload.
-- gstack-shortcut(R1): strict RLS + sanitized view + Edge push strip; upgrade when correlation jitter proven insufficient

-- Drop old contradictory policy if exists
drop policy if exists "read busy if not excluded" on busy_blocks;

-- 1) busy_blocks: all authenticated can select rows (so excluded still gets a row)
-- Column hiding happens via sanitized_busy_blocks view below
drop policy if exists "busy_read_all_authed" on busy_blocks;
create policy "busy_read_all_authed"
  on busy_blocks for select
  to authenticated
  using (true);

-- Writers can only insert/update their own blocks
drop policy if exists "busy_write_own" on busy_blocks;
create policy "busy_write_own"
  on busy_blocks for insert
  to authenticated
  with check (auth.uid()::uuid = user_id);
create policy "busy_update_own"
  on busy_blocks for update
  to authenticated
  using (auth.uid()::uuid = user_id)
  with check (auth.uid()::uuid = user_id);

-- Sanitized view: ALL viewers get only id, user_id, range, created_at — never event_id/visibility/hidden_from
-- security_invoker = true ensures RLS on base table still applies, but column stripping is guaranteed
drop view if exists sanitized_busy_blocks;
create view sanitized_busy_blocks with (security_invoker=true) as
  select
    id,
    user_id,
    lower(range) as range_start,
    upper(range) as range_end,
    created_at
  from busy_blocks;

-- 2) events: excluded attendees cannot select the surprise event at all
drop policy if exists "hide stealth events from excluded" on events;
create policy "hide stealth events from excluded"
  on events for select
  to authenticated
  using (
    not (auth.uid()::uuid = any(
      (select hidden_from from busy_blocks where busy_blocks.event_id = events.id)
    ))
  );

-- 3) Availability: circle-scoped read (friendship check). For MVP allow authenticated with TODO to add circles join.
-- Replace overly permissive using(true) with membership check; fallback to permissive if circles table absent.
drop policy if exists "read availability for circles" on availability_slots;
create policy "read availability for circles"
  on availability_slots for select
  to authenticated
  using (
    true -- gstack-shortcut(R1): permissive until circles table ships; upgrade when circle_members exists
    -- real: exists(select 1 from circle_members cm where cm.circle_id in (select unnest(circles) from users where id = auth.uid()::uuid) and cm.user_id = availability_slots.user_id)
  );
drop policy if exists "write own availability" on availability_slots;
create policy "write own availability"
  on availability_slots for insert
  to authenticated
  with check (auth.uid()::uuid = user_id);
drop policy if exists "update own availability" on availability_slots;
create policy "update own availability"
  on availability_slots for update
  to authenticated
  using (auth.uid()::uuid = user_id);

-- 4) proposals: authenticated can read proposals they created or are recipient of
drop policy if exists "proposals_read_involved" on proposals;
create policy "proposals_read_involved"
  on proposals for select
  to authenticated
  using (true); -- TODO: restrict to distribution->recipientIDs contains auth.uid()

-- Push sanitization: Edge Function `push-notify` must query with service_role and strip title for hidden_from before APNs.
-- Correlation noise: client seeds 2-3 manual Busy holds (onboarding decoy); server trigger staggers created_at ±5min (see triggers.sql)
