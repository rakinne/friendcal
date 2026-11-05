# Decisions — FriendCal

## Phase 1 scaffold (2026-11-04)
- Backend: **Supabase** (Postgres + RLS + Realtime + Auth + Edge Functions) — chosen 2026-11-04 (Option A). RLS on `busy_blocks.hiddenFrom` enforces stealth; Realtime on AvailabilitySlot/BusyBlock for live heatmap; Edge Function for sanitized APNs payload. Firebase was alt, CloudKit rejected (no cross-user RLS). See D1.
- Manual Busy: user-creatable (required for stealth cover traffic) — resolves open question per eng-review P2.
- Wheel favorites: cap 10 + drawer overflow — resolves wheel size open question.
- Poke: rate limit 1 per (from,to,proposal) per 24h; mute per user.
- Distribution: separate `Distribution` struct (mode: separately|newGroup) from Proposal — eng-review P2 fix applied.
- SoftHold lifecycle: AvailabilitySlot state free→softHold→busy with expiresAt; promote on lock, expire stale — fixes dual-purpose over-blocking.
- Privacy: StealthService sanitizes BusyBlocks for hiddenFrom viewers; identical BusyBlockView styling; correlation-noise hooks for jitter/decoy.
