# TODOS

## Home

### "What changed since last visit" cue on Home

**What:** On a return visit, highlight what changed since the user last opened Home: a one-time coral blink on newly free friends' faces, and/or a "+N since yesterday" note on the best heatmap cell.

**Why:** The design doc's success metric is daily wheel opens without a pending proposal. Today a return visit looks identical unless the user notices a changed number.

**Context:** Raised in the 2026-11-06 /plan-design-review of issue #4 (journey storyboard step 8, decision D37). Home is fixture-only in #4, so there's no real change data. Respect DESIGN.md motion (one authored moment, Reduce Motion falls back to color only) and D23 (only the active arc pulses continuously). Start from the LIVE single-pulse-on-change behavior in D23.

**Effort:** M
**Priority:** P3
**Depends on:** Supabase Realtime wiring for Home (out of scope in #4), plus a persisted "last seen" timestamp per user.

## Backend

### Snap lock window bounds to whole minutes before wiring lockProposal

**What:** Round the common window's start and end to whole minutes before `SupabaseService.lockProposal(_:window:)` sends them, and/or compare `date_trunc('milliseconds', …)` in `lock_proposal()`.

**Why:** supabase-swift encodes `Date` at 3 fractional digits (truncating). A window start with sub-millisecond precision lands just below the true bound, so `range_agg(...) @> window` fails for the recipient whose hold starts there: their holds are deleted and they get no Busy block.

**Context:** Owner-ruled note from the 2026-11-06 /ship of eng/t1-core-dedupe (approval a-2e165bc43fc4, final-tree adversarial finding 1). Latent: nothing calls `lockProposal` yet. Add a test that locks a window whose start has microseconds.

**Effort:** S
**Priority:** P1
**Depends on:** Wiring the Supabase backend (docs/TODOS.md "Wire Supabase Swift SDK").

### Make lock server-first when wiring the backend

**What:** Split `ProposalService.lock` into validate-and-return-window, then `await lockProposal`, and only then set `status`, `lockedDate` and `lockedEnd` (or refetch). Show the server's 22023/40001 refusals in the UI.

**Why:** Today `lock` marks the proposal locked locally before any server call, and the client heatmap ignores existing Busy blocks while the server excludes busy recipients from quorum, so the UI can show a lock the server refused.

**Context:** Owner-ruled note, 2026-11-06 /ship (a-2e165bc43fc4, findings 7). `busyWriter` is synchronous and cannot carry the async RPC. Quorum is already pinned client/server (ProposalTests.testClientQuorumMatchesServerQuorum).

**Effort:** M
**Priority:** P1
**Depends on:** Wiring the Supabase backend.

### Harden lock_proposal before production

**What:** In `supabase/lock_proposal.sql`: build `v_window` after the window checks (inverted windows give a raw 22000), order advisory locks by their hash key, set `search_path = public, pg_temp`, use `clock_timestamp()` for expiry, reject softHold inserts/updates on proposals that are not `requesting` (a hold created mid-lock is orphaned), and confirm the function owner has BYPASSRLS on the real project (it writes other users' rows).

**Why:** All six are below the blocking floor today because nothing calls the RPC, but each is a correctness or hardening gap once it is live.

**Context:** Owner-ruled notes, 2026-11-06 /ship (a-2e165bc43fc4, findings 2-6, 8). Extend supabase/tests/lock_proposal_test.sql for each; scripts/test-sql.sh runs it.

**Effort:** M
**Priority:** P1
**Depends on:** None
