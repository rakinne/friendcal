# Decisions — FriendCal

## Phase 1 scaffold (2026-11-04)
- Backend: **Supabase** (Postgres + RLS + Realtime + Auth + Edge Functions) — chosen 2026-11-04 (Option A). RLS on `busy_blocks.hiddenFrom` enforces stealth; Realtime on AvailabilitySlot/BusyBlock for live heatmap; Edge Function for sanitized APNs payload. Firebase was alt, CloudKit rejected (no cross-user RLS). See D1.
- Manual Busy: user-creatable (required for stealth cover traffic) — resolves open question per eng-review P2.
- Wheel favorites: cap 10 + drawer overflow — resolves wheel size open question.
- Poke: rate limit 1 per (from,to,proposal) per 24h; mute per user.
- Distribution: separate `Distribution` struct (mode: separately|newGroup) from Proposal — eng-review P2 fix applied.
- SoftHold lifecycle: AvailabilitySlot state free→softHold→busy with expiresAt; promote on lock, expire stale — fixes dual-purpose over-blocking.
- Privacy: StealthService sanitizes BusyBlocks for hiddenFrom viewers; identical BusyBlockView styling; correlation-noise hooks for jitter/decoy.

## Apple block lanes (2026-11-07) — 0.1.1.0

While blocked on Apple Developer verification (~1 day), shipped server rules + auth state + Me surface instead of waiting. CEO review C1-C10 batched four lanes by unblockability, not tab count.

- **RLS hardening (C1):** Three `using(true)` policies were the real leak — any signed-in user could read every proposal/slot/hidden_from. Fixed with row-scoped selects on `proposals` + `availability_slots`, column grants on `busy_blocks` (rows stay readable per premise 7 — excluded viewer must see generic grey block, not a hole), and scoped `events` reads. `supabase-stubs.sql` now mirrors Supabase table grants so `rls_test.sql` is non-vacuous (fail on `main`, pass here).
- **Auth + Me (C2):** State machine behind `ProposalStore` + `AuthGate` + `MeView` (sign out, withheld-name prompt, delete account). Only `ASAuthorizationController` hop is Apple-gated.
- **My Commitments (C3):** `my_commitments(p_from)` security-definer RPC — one bounded readReturning provenance + authorized titles. Absorbed three eng obligations into one.
- **Groups/Poke build deferred (C4/C5):** Group-as-denominator reopens D13; Poke without APNs has no value. Design session for Poke contract ships now (C6).
- **Account deletion (D8/D10):** `delete_account()` RPC — delete identity, anonymize row, keep locked plans. Verified by `users_auth_test.sql`.
- **Target honestly lowered (D7):** This wave does *not* make two phones converge; `SupabaseProposalStore` is next wave.
- **Apple revocation out of wave (re-cost D2/eng D7):** Auth code single-use/5-min + needs team-signed client secret — would gate submission on verification. Deferred with unconditional Settings fallback.
- **Poke limit replaced (social wave, 2026-11-10):** one live poke per (from, to); a re-send returns the existing poke; a poke expires after one hour. Supersedes the 24h per-proposal rule from 2026-11-04. Enforced in `supabase/social.sql`.
