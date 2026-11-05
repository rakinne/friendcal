-- RLS: Stealth invariant — excluded viewer (hidden_from) must not receive event payload
-- Strategy: two-layer — row visibility + column stripping via view.
-- Client uses `sanitized_busy_blocks` view when rendering wheel/profile for another user.

-- 1) busy_blocks: included viewers see full row; excluded viewers see sanitized via view below.
-- Base policy: authenticated users can read blocks where they are not excluded OR they are owner
create policy "read busy if not excluded"
  on busy_blocks for select
  using (
    auth.uid()::uuid = user_id
    or not (auth.uid()::uuid = any(hidden_from))
  );

-- For excluded viewers we still return a row (so they see grey Busy) but via view that hides event_id/visibility
create or replace view sanitized_busy_blocks as
  select
    id,
    user_id,
    range,
    -- Intentionally omit event_id, visibility, hidden_from for excluded path
    created_at
  from busy_blocks;

-- 2) events: excluded attendees cannot select the surprise event at all
create policy "hide stealth events from excluded"
  on events for select
  using (
    not (auth.uid()::uuid = any(
      (select hidden_from from busy_blocks where busy_blocks.event_id = events.id)
    ))
  );

-- 3) Availability: users read own + friends' slots for heatmap (friendship check omitted for MVP — add via circles table)
create policy "read availability for circles"
  on availability_slots for select using (true);
create policy "write own availability"
  on availability_slots for insert with check (auth.uid()::uuid = user_id);
create policy "update own availability"
  on availability_slots for update using (auth.uid()::uuid = user_id);

-- Push sanitization: Edge Function `push-notify` must query with service_role and then strip title for hidden_from before APNs.

-- Correlation noise: encourage onboarding decoy — client seeds 2-3 manual Busy holds; server staggers writes by randomizing created_at ±5min in trigger (see triggers.sql)
