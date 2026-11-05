# TODOS — FriendCal

## P0
- [x] Fix stealth correlation leakage: scaffold StealthService with sanitize + correlation-noise hooks; BusyBlockView uses identical styling. Still need server-side RLS + decoy-noise onboarding.
- [x] Define SoftHold vs Hard Busy lifecycle: AvailabilitySlot with softHold state + expiresAt, AvailabilityService tapFreeSlot/promote/expire.
- [x] Choose backend: **Supabase** (A) — SupabaseService scaffold + schema.sql + rls.sql (RLS on busy_blocks.hiddenFrom, Events exclusion, sanitized view). TODO: wire Supabase Swift SDK + Realtime + APNs Poke.
- [ ] Manual QA: surprise-brunch blind test — Mica→Jalen Nov 7 Mardi Gras Tuesday: Jalen on wheel+profile must see only grey Busy (no 📍/title/avatar), identical styling, push sanitized ("New busy time added"), correlation test: 3 friends busy same slot → still indistinguishable (Mica→Jalen Nov 7 Mardi Gras Tuesday)

## P1
- [ ] Model location/far: venue + proximity on Proposal/Event; "Who else is far?" filtering.
- [x] Wheel favorites cap 10 + drawer overflow (MyFavesWheelView).
- [x] Distribution split from Proposal (Distribution struct).

## P2
- [x] Invite art async off lock (Event.inviteArtTemplate), heatmap debounce note in HeatmapView.
- [ ] Add TicketTap Tag Along card with purchaseLinks + Partiful-style hype generation on lock.

Source: /plan-eng-review 2026-11-04 + scaffold 2026-11-04

- [ ] Wire Supabase Swift SDK (add package), connect SupabaseService to real client, test Realtime heatmap + Edge Function push
