# TODOS

## Home

### "What changed since last visit" cue on Home

**What:** On a return visit, highlight what changed since the user last opened Home: a one-time coral blink on newly free friends' faces, and/or a "+N since yesterday" note on the best heatmap cell.

**Why:** The design doc's success metric is daily wheel opens without a pending proposal. Today a return visit looks identical unless the user notices a changed number.

**Context:** Raised in the 2026-11-06 /plan-design-review of issue #4 (journey storyboard step 8, decision D37). Home is fixture-only in #4, so there's no real change data. Respect DESIGN.md motion (one authored moment, Reduce Motion falls back to color only) and D23 (only the active arc pulses continuously). Start from the LIVE single-pulse-on-change behavior in D23.

**Effort:** M
**Priority:** P3
**Depends on:** Supabase Realtime wiring for Home (out of scope in #4), plus a persisted "last seen" timestamp per user.

### Heatmap vs. Busy blocks: reconcile with X1

**What:** Decide whether the heatmap may subtract recipients whose sanitized Busy blocks intersect a cell's common window (busy existence is already visible to every signed-in user), or keep X1 strict and rely on the server refusal at lock. If allowed, `HeatmapBuilder.weeks` gains `busy: [SanitizedBusy]` and the roster marks those recipients busy.

**Why:** A friend who tapped free and was later locked into another plan still counts in the client's commonCount; `lock_proposal` excludes them, so the creator can see "12 of 15" and get "need 80 percent free". The number the creator sees should be the number the server accepts.

**Context:** Raised by the 2026-11-06 /plan-eng-review of issue #5 (outside-voice finding O5, decision D20). X1 (issue #4 review) forbids Home from reading BusyBlocks because a stealth plan's attendees all dropping out of one cell is the correlation signal it hides, so this is a privacy decision before it is a code change. Today the server refusal is shown verbatim and the session reloads. Start at `HeatmapBuilder.isEligible` and the X1 record in `~/.gstack/projects/friendcal/main-eng-review-20261105-235412.md`.

**Effort:** M
**Priority:** P2
**Depends on:** Issue #5 PR2 (real Busy blocks exist only after real locks); a privacy decision on X1.

### Lock morph: peak cell → invite card

**What:** DESIGN.md's one authored motion moment: when a time locks, the heatmap's peak cell morphs into the invite card (shared element across Home and the invite), the wheel contracts to a success halo, three confetti dots settle; an immediate color-only equivalent under Reduce Motion.

**Why:** It is the design system's stated signature moment. Issue #5 ships a placeholder (success haptic plus 320 ms crossfades of the badge and scrim text, design decision 3.4A).

**Context:** Raised by the 2026-11-06 /plan-design-review of issue #5 (T2). Start at `LockedInviteView`'s badge crossfade and `HeatmapCard`'s best cell; `matchedGeometryEffect` across tabs is the hard part. DESIGN.md Motion section has the timing (spring damping 0.82, no overshoot; 30 ms cell stagger).

**Effort:** M
**Priority:** P2
**Depends on:** Issue #5 PR1 (the locked state and the invite screen).

## Backend

### Make lock server-first when wiring the backend

**What:** Split `ProposalService.lock` into validate-and-return-window, then `await lockProposal`, and only then set `status`, `lockedDate` and `lockedEnd` (or refetch). Show the server's 22023/40001 refusals in the UI.

**Why:** Today `lock` marks the proposal locked locally before any server call, and the client heatmap ignores existing Busy blocks while the server excludes busy recipients from quorum, so the UI can show a lock the server refused.

**Context:** Owner-ruled note, 2026-11-06 /ship (a-2e165bc43fc4, findings 7). `busyWriter` is synchronous and cannot carry the async RPC. Quorum is already pinned client/server (ProposalTests.testClientQuorumMatchesServerQuorum). Issue #5 PR1 landed the client half: `ProposalService.validateLock(cell:duration:)` is pure, `ProposalSession.lock` awaits `ProposalStore.lock` and applies the returned proposal, and `UserFacingError` maps the refusals; the remaining half is `SupabaseProposalStore.lock` calling the RPC (PR2).

**Effort:** M
**Priority:** P1
**Depends on:** Wiring the Supabase backend.

### Harden lock_proposal before production

**What:** In `supabase/lock_proposal.sql`: build `v_window` after the window checks (inverted windows give a raw 22000), order advisory locks by their hash key, set `search_path = public, pg_temp`, use `clock_timestamp()` for expiry, reject softHold inserts/updates on proposals that are not `requesting` (a hold created mid-lock is orphaned), and confirm the function owner has BYPASSRLS on the real project (it writes other users' rows).

**Why:** All six are below the blocking floor today because nothing calls the RPC, but each is a correctness or hardening gap once it is live.

**Context:** Owner-ruled notes, 2026-11-06 /ship (a-2e165bc43fc4, findings 2-6, 8). Extend supabase/tests/lock_proposal_test.sql for each; scripts/test-sql.sh runs it. Scheduled: issue #5 PR2 (2026-11-06 /plan-eng-review, D15).

**Effort:** M
**Priority:** P1
**Depends on:** None

## Invites

### Next step for a friend who wasn't free

**What:** Give the locked-out state on the invite ("Locked without you. You weren't free then.", design decision 2.1A) one action: "Suggest another time" (a new plan prefilled with the same crew) or a Tag Along "I'll come late" that records them as a maybe.

**Why:** A friend who misses the lock is the moment people drift; today the line is honest but ends there.

**Context:** Raised by the 2026-11-06 /plan-design-review of issue #5 (T3). Start at `LockedInviteView`'s non-attendee caption; design doc premises 4 (Tag Along) and 6 (Poke). Needs either Tag Along semantics or an attendee "maybe" state the schema does not have.

**Effort:** M
**Priority:** P3
**Depends on:** The Tag Along issue, or an attendee "maybe" state on locked proposals.

## Links

### Universal links + not-installed fallback

**What:** An `applinks:friendcal.app` associated domain, an `apple-app-site-association` file hosted at the domain, `https://friendcal.app/p/<id>` as the shared link (`DeepLink` parses both the https form and `friendcal://proposal/<id>`), and a static fallback page at that URL ("Get FriendCal on TestFlight" with the public TestFlight link) for friends without the app.

**Why:** The custom scheme chosen for issue #5 (decision D3) dead-ends when the app is not installed, and any app can claim `friendcal://`. Every share link should work for every friend.

**Context:** Raised by the 2026-11-06 /plan-eng-review of issue #5 (finding A8, decision D16). The web mockup already shows `friendcal.app`. Start at `DeepLink.swift` (add the https form), `app/project.yml` (associated domains entitlement), and a static host for the AASA and fallback page; Apple caches AASA, so changes take time to propagate. The fallback page is the first web presence the design doc lists ("optional web for invite art sharing").

**Effort:** M
**Priority:** P2
**Depends on:** Issue #5 PR2 (Team ID, entitlements); owning friendcal.app; a public TestFlight link.

## Completed

### Snap lock window bounds to whole minutes before wiring lockProposal

Done in issue #5 PR1 (decision D18): `ProposalService.validateLock(cell:duration:)` rounds the window start down and the end up to whole minutes, and `AvailabilityService.promoteToBusy` judges coverage at minute granularity; `ProposalTests.testValidateLockSnapsToWholeMinutesAndMicrosecondHoldPromotes` locks a window whose common start carries microseconds. Original note: 2026-11-06 /ship (a-2e165bc43fc4, finding 1).
