# Eng Review: FriendCal — TestFlight Slice (branch diff)

**Target:** `codex/ship-phase1-fixes` diff vs origin/main (19ebea3) — scaffold for TestFlight
**Design source:** DESIGN.md (Kinetic Warmth, Variant A approved #FF4E2E on #FBF1E5) + docs/designs/friendcal-hub.md (Approach B Ideal Hub, Status: APPROVED, Builder mode)
**Date:** 2026-11-05
**Reviewer:** plan-eng-review interactive

## Scope Challenge — ACCEPT as-is, phased
Goal is TestFlight for founding friend group (high trust, low app-switch tolerance, iMessage is incument). Minimum to beat iMessage poll: Proposal → Request for Times (Distribution separately/newGroup) → tap free → SoftHold pre-commit → Heatmap convergence → Lock → BusyBlocks with stealth. Wheel home + Poke needed for DAU; Tag Along + Partiful art + Ghost can be TestFlight 2.

Complexity gate trips (~12 new files / 4 services). Mitigate via 3 lanes, not cut:
- Lane 1 (TestFlight 1): Proposal/Availability/Heatmap + Stealth Busy + Supabase RLS + manual Busy cover traffic + APNs sanitized
- Lane 2: Wheel favorites 10-cap + drawer + profile sheets + Poke rate-limit + Realtime heatmap
- Lane 3: TicketTap Tag Along + invite art generation on lock

Finding SC-1 [P1] (8/10) app/FriendCal/FriendCalApp.swift:10 — ContentView is placeholder wheel + text. No Proposal creation UI, no nav, no Supabase wiring. Not TestFlight-shippable without Lane 1 end-to-end wired.

## Decision Ledger

### R1 — Stealth enforcement (P0) — APPROVED A
User confirmed A 2026-11-05 for D2: Strict RLS + sanitized_busy_blocks view + Edge Function push stripping.
Accepted scope: server-enforced invariant (see report header). Client sanitize becomes defense-in-depth + jitter/decoy.
See prior eng review P0 stealth correlation leakage — now tightened.

---

## 1. Architecture Review

**[P0] (9/10) supabase/rls.sql:12–22 — RLS policy blocks row vs. requirement to show grey Busy**
`"read busy if not excluded"` does `using(auth.uid()=user_id OR NOT auth.uid()=ANY(hidden_from))` — excluded Jalen gets zero rows, so wheel shows nothing, not indistinguishable Busy. But `sanitized_busy_blocks` view still selects from `busy_blocks` under same RLS, so it also returns zero rows. Violates "indistinguishable" — need allow select for all authed, but hide columns via view for hidden viewers. Fix: base policy `using(true)` for authed + view strips `event_id/visibility/hidden_from`; or better, two policies: `FOR SELECT TO authenticated USING (true)` + view enforces column hiding via `security_invoker` semantics. Currently breaks stealth promise.
Quote: `create policy "read busy if not excluded" on busy_blocks for select using ( auth.uid()::uuid = user_id or not (auth.uid()::uuid = any(hidden_from)) );` and `create or replace view sanitized_busy_blocks as select id, user_id, range, created_at from busy_blocks;`

**[P0] (9/10) app/FriendCal/Services/SupabaseService.swift:38 — fetchBusyBlocks casts sanitized view to BusyBlock**
View omits hidden_from/event_id/visibility but `execute().value as [BusyBlock]` expects full BusyBlock Codable with hiddenFrom array. Decode fails or silently drops stealth flag. Must decode `[StealthService.SanitizedBusy]` for excluded path and map to UI; included path needs separate query joining events.

**[P1] (8/10) supabase/rls.sql:28 — Availability policy `using(true)` over-permissive**
`create policy "read availability for circles" on availability_slots for select using (true);` — any authed user reads all users' slots. Plan requires circle-scoped read (friendship/membership check). Leaks global availability beyond group. Fix before TestFlight: `using(exists(select 1 from circle_members where ...))` or at least `auth.uid() IN (select member from proposals distribution)`.

**[P1] (8/10) app/FriendCal/Models/AvailabilitySlot.swift:7 — SoftHold lifecycle not persisted**
`AvailabilitySlot.state=softHold` + `expiresAt` exists in model but no expiry enforcement outside `expireStaleHolds` filter. No timer, no DB TTL, no lock promotion. Tapping 3 Saturdays creates 3 SoftHolds that remain indefinitely, over-blocking to other friends' heatmaps. Need: DB `expires_at` default + cron/Edge Function `REAPER` + `promoteToBusy(onLock:)` transaction that promotes winner + expires losers atomically.

**[P1] (7/10) app/FriendCal/Services/ProposalService.swift:9 — Lock does not enforce heatmap quorum**
`lock(_:to:busyWriter:)` sets `lockedDate` unconditionally. No check that `freeCount == totalRecipients` or "best" consensus, so one friend can lock out others. Add `guard heatmapRow(for: date).coverage >= threshold else throw` and require creator role.

## 2. Code Quality Review

**[P1] (8/10) app/FriendCal/Views/Wheel/MyFavesWheelView.swift:18 — Hard-coded geometry ignores Dynamic Type + accessibility**
`let radius = min(geo.size.width,height)*0.35` + `FriendFaceView frame 56` + `GhostView Text("👻")`. No size-class, no `\.accessibilityReduceMotion`, no spring config per DESIGN.md "wheel settles with spring". Missing pulsing spec (ember coral pulse only on active arcs). Recommend: extract DesignTokens, add `withAnimation(.spring(response:0.5, damping:0.8))` for settle, `accessibilityLabel` already present but needs `VoiceOver` rotor.

**[P2] (7/10) app/FriendCal/Views/Proposal/HeatmapView.swift:5 + BusyBlockView.swift:8 — Hard-coded colors bypass DESIGN.md tokens**
`Color.green/.yellow/.red` and `Color.gray.opacity(0.35)` + `Color(.systemGray6)` ignore tokens: `primary #FF4E2E`, `accent #18A99A`, `peach`, `border #EADCCB`, `surface #FFF8EF`. Violates AGENTS.md guard "DESIGN.md is visual source of truth". Extract `DesignTokens` enum and use semantic levels (green = primary pulse, yellow = peach, red = border-muted).

**[P2] (6/10) supabase/schema.sql — Missing FK indexes and tstzrange exclusion constraint**
`busy_blocks.range tstzrange` + `availability_slots.range tstzrange` without GiST indexes or exclusion constraint `EXCLUDE USING gist (user_id WITH =, range WITH &&) WHERE (state='busy')`. Concurrent taps on overlapping ranges can double-book. Add index + constraint or app-level advisory lock.

## 3. Test Review

Current: `FriendCalTests/AvailabilityTests.swift:3` + `StealthTests.swift:5` — 5 tests pass, 2 are `XCTAssertTrue(true)` placeholders.

```
Propose → Request → Tap → Heatmap → Lock → Busy
  ├─ ProposalService.createProposal + distribution modes [GAP]
  ├─ AvailabilityService.tapFreeSlot SoftHold + expiresAt [PARTIAL: tapFreeCreatesSoftHold passes, but no collision/over-block test]
  ├─ HeatmapRow coverage/level + debounce 500ms note [GAP: no perf test]
  ├─ ProposalService.lock quorum + promoteToBusy transaction [GAP]
  ├─ StealthService.sanitize — excluded sees SanitizedBusy only [PARTIAL: excludedSeesGenericBusy passes]
  ├─ StealthService correlation (3 friends same slot indistinguishable) [PLACEHOLDER — testCorrelationNoiseDoesNotRevealGrouping is XCTAssertTrue(true)]
  ├─ Stealth push body sanitized [GAP]
  ├─ SupabaseService RLS view decode [GAP]
  ├─ Poke rate-limit 1/(from,to,proposal)/24h + mute [GAP]
  └─ Wheel 10-cap overflow + drawer [GAP]
```

Coverage: 2/28 paths partially, 26 GAP. P0 gaps are stealth correlation + promotion atomicity — must add before TestFlight TestPlan flight.

## 4. Performance Review

**[P2] (6/10) Heatmap fan-out — Realtime subscription per Proposal without batching**
`SupabaseService.subscribeRealtime(onProposal:)` creates `client.channel("proposal-\(id)")` per proposal, no circle-scoped batching. With 15 recipients each tapping 6 slots, N=90 writes fan out to N channels. Recommend: single `availability_slots` channel filtered by `source_proposal_id IN (user's proposals)`, debounce heatmap recompute 500ms (note in HeatmapView.swift:5 but not implemented), use `Combine.debounce` or `AsyncStream` coalescing.

**[P2] (5/10) App launch — Secrets.plist load in SupabaseService.fromSecrets()**
Synchronous `Data(contentsOf:)` + plist parse on main thread if called from App init. Not measured but could add 50-150ms on cold launch. Move to `Task` + cache.

## What already exists — KEEP
- DESIGN.md spec + variant A artifacts (pulled, warm paper tokens)
- Models clean, Distribution extracted (fixed prior P2)
- SoftHold state modeled, privacy manifest stub
- Supabase schema scaffold with pgcrypto, RLS enabled

## NOT in scope
- Tag Along deep-links, invite art generation, Ghost behaviors — deliberate defer to Lane 3
- Web invite sharing — optional per friendcal-hub.md distribution plan
- Dark mode — DESIGN.md explicitly light-only for warmth/legibility

## Failure modes — critical gaps
1. **Stealth proxy leak** — client receives hiddenFrom before sanitize (SupabaseService fetchBusyBlocks mock path). Blind test fails on packet inspect.
2. **Availability over-block** — SoftHold never expires cluster-wide, blocks explorer who taps multiple dates from being invited elsewhere.
3. **Poke spam** — no rate limit enforcement; Poke model documents 24h limit but service has no guard, could spam push.

## TODOS.md updates (proposed)
- [ ] Fix RLS to allow grey Busy for excluded viewer (allow select, hide columns via view) + fix fetchBusyBlocks decode to SanitizedBusy
- [ ] Implement Availability expiry reaper + atomic promoteOnLock transaction
- [ ] Wire Proposal create→heatmap→lock end-to-end for TestFlight 1 lane
- [ ] Add lock quorum check (require best/coverage threshold)
- [ ] Add 6 missing tests (correlation blind test, push sanitization, rate-limit, heatmap convergence, RLS decode, over-block collision)
- [ ] Extract DesignTokens + match wheel/heatmap to DESIGN.md colors + spring motion

## Parallelization
Lane A (backend/privacy): RLS + view + Edge Function push strip + schema indexes
Lane B (app/loop): Availability expiry + lock quorum + heatmap debounce + TestFlight provisioning (bundle, signing, privacy manifest)
Lane C (polish): Wheel cap/drawer + BusyBlockView tokens + Poke UI
B depends on A for busy read; C can parallel after tokens.

## Lake Score
Not scored this review (no completeness-scored decisions beyond stealth A=10/10).

