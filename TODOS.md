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

### Runbook for applying this wave's SQL to a real Supabase project

**What:** A short, ordered procedure for applying `schema.sql`, `schema_additions.sql`,
`lock_proposal.sql`, `rls.sql`, `users_auth.sql`, `join_proposal.sql`, `commitments.sql` and the
places file (`places.sql`, issue #11) to a real project, including what to do when it errors
mid-file. The edit guard lives in `rls.sql` and the commitments RPC in `commitments.sql`; the
earlier names `proposals_edit_guard.sql` and `my_commitments.sql` do not exist. The load order is
`WAVE_SQL` at `scripts/test-sql.sh:60-63`, with `places.sql` after it. State one deploy-order rule:
`lock_proposal` reads the places tables when it runs, so `places.sql` must be applied before anyone
locks a plan on that project (2026-11-08 `/plan-eng-review` of #11 and #12, C-6, D7).

**Why:** The 2026-11-07 CEO review's live Postgres probe found that under `--single-transaction` —
the mode `schema.sql:2` tells you to use — `rls.sql` errors at `:49` and aborts eight follow-on
statements, leaving **zero policies and all four tables denying everything**. That fails closed,
which is the right direction, but the operator sees one error message and has no stated recovery.

**Context:** Found by the 2026-11-07 `/plan-ceo-review` re-cost (Section 9 CRITICAL GAP, decision
D5). `scripts/test-sql.sh:38-62` already encodes the working order for the test harness and is the
source to transcribe from; what it does not encode is recovery from the single-transaction abort,
which is the failure the probe actually found. E9 raises the Postgres floor to 15, which the runbook
should state, because `security_invoker` does not exist in 14 and `test-sql.sh:16` would silently
select it if 15 were absent.

**Effort:** S
**Priority:** P2
**Depends on:** Lane 1's SQL existing. Trigger: before the first real Supabase project is created,
which is task E21's moment.

### Realtime publication for the tables the client subscribes to

**What:** The `realtime.sql` publication from issue #5 PR2 §4 — adding the tables `changes(for:)`
subscribes to into the Supabase Realtime publication, plus an assertion of publication membership
once there is a Realtime service to assert against. The list includes the two place-voting tables,
`proposal_places` and `place_votes` (issue #11), or a friend's new suggestion or vote appears only
after a manual refresh, with no error (2026-11-08 `/plan-eng-review` of #11 and #12, D8).

**Why:** Accepted into Lane 1 by CEO D2 (which incorporates PR2 §4 wholesale) and carried by the
2026-11-07 CEO review's own task T7, but **absent from the live 43-task engineering list with no
decision moving it** — found by the 2026-11-07 re-cost while reconciling prior task lists. Without
it, the next wave's `changes(for:)` subscribes to tables that publish nothing and live updates
silently never arrive.

**Context:** Deferred out of Lane 1 by decision D7 on 2026-11-07, because `changes(for:)` inside
`SupabaseProposalStore` is its only consumer and that is next-wave work (CEO D7), so publication
membership cannot be meaningfully verified this wave. One `alter publication` statement plus a test
row; roughly 20 CC-minutes. The scope document's Lane 1 line now names this as its one exception to
"PR2 §4" so the plan and the task list agree.

**Effort:** S
**Priority:** P2
**Depends on:** `SupabaseProposalStore` (task E20), which is what consumes it.

### A decision record in the repository

**What:** Two steps. (1) Commit `docs/designs/friendcal-blocked-day-scope.md`, which is **untracked**
today. (2) Add the engineering decisions and their one-line rationales to `docs/DECISIONS.md` — the
eng delta review's D1-D9 and the CEO re-cost's D2-D7 — so the reasoning behind the privacy boundary
lives in the repo rather than only in review transcripts.

**Why:** Verified on 2026-11-07: a fresh clone at `30f9261` carries **none** of the five review
artifacts. The scope document is untracked and `TODOS.md`'s additions are uncommitted, so the
reasoning for revoking three columns from `busy_blocks`, for `my_commitments()` existing as a definer
function at all, and for what "deleted" means is reachable only from one machine's home directory.
This is the second occurrence of a failure the design review already diagnosed for its own half:
design 1.3A was approved and then lived only inside a review file until a later review found five
surfaces with no DESIGN.md entry.

**Context:** Found by the 2026-11-07 `/plan-ceo-review` re-cost (Section 10 CRITICAL GAP, sharpened
by the Codex outside voice, decision D6). The requirement is the decisions and their rationale, not
the ~450 KB of transcripts. `docs/DECISIONS.md` already exists as Lane 4's artifact destination, so
there is a file to extend rather than invent. Task G12 covers the design half by writing five
Components entries into DESIGN.md; nothing covered the engineering half.

**Effort:** S
**Priority:** P2
**Depends on:** None. The decisions already exist in writing — just not in the repository.

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

## Groups

### Groups as a real entity (saved crew as proposal recipients)

**What:** Wire the existing `circles` and `circle_members` tables (`supabase/schema.sql:73,78`) with
RLS, add a Groups screen on the Groups tab (`app/FriendCal/Views/Shell/AppTabView.swift:45` is a
stub), and let a saved group be the recipients of a new plan from `CreateProposalSheet`.

**Why:** today the only distribution path is re-sharing a link to ten people. Picking
"Friendsgivemas crew" is the design doc's Circle/Group entity (`docs/designs/friendcal-hub.md:44`).
It would also close the `gstack-shortcut(R1)` at `supabase/rls.sql:58`, which names `circle_members`
as its own upgrade trigger — though issue #5 D6's proposal-scoped RLS supersedes that marker, so
Groups is no longer required for the privacy boundary.

**Context:** Deferred by the 2026-11-07 /plan-ceo-review (decision D4). **Deferral reason:** a saved
group wants to be the quorum denominator, which reopens issue #5 D13 (`total = max(expected_count,
joined)`, chosen deliberately because join-by-link makes the joined set the wrong denominator — the
creator alone would reach 80% with one tap). It also adds a second membership model beside proposal
recipients, before a single plan has been locked across two phones. Revisit once one real group has
used the loop twice. `struct Circle` (`app/FriendCal/Models/User.swift:20`) is declared and has no
reference anywhere; decide whether it survives when this is picked up.

**Effort:** L
**Priority:** P3
**Depends on:** Issue #5 PR2 landing; a decision on whether a group or `expected_count` owns the
quorum denominator (reopens D13).

## Places

### Show the winning place on the Invites list and My commitments rows

**What:** Add the winning place name to a locked plan's row on the Invites list ("Locked · Sat, Nov 14 · 10:00–12:00") and to its My commitments row, with a truncation rule for long names.

**Why:** People check the Invites tab to remember a plan, and the place is part of the answer to "where". Issue #10's rule R8 stops at the locked card and the share text, so the list rows say only when.

**Pros:** Completes the story for friends who never reopen the invite; it is a small text change once the winner is on the proposal.

**Cons:** It goes past what R8 says, adds a row-width and truncation decision on a dense list, and needs fixture and UI-test updates.

**Context:** Raised by the 2026-11-08 `/plan-design-review` of place voting (#13) and deferred by the owner (TODO decision D30, option A). Start at the status line in `app/FriendCal/Views/Invites/InvitesView.swift` and at `CommitmentRow` in `app/FriendCal/Views/Me/MyCommitmentsView.swift`. R8 and decision 1.4A in `docs/designs/friendcal-places.md` define what is in scope today. When the lock morph TODO above is built, the winner row should join it.

**Effort:** S
**Priority:** P3
**Depends on:** Issue #12 (the winner on the proposal) and issue #14 shipped.

## Poke

### Poke's build: pokes table, Edge Function, APNs, inbox

**What:** A `pokes` table, an Edge Function that sends the sanitized push, APNs configuration,
device-token registration, and a Pokes inbox on the Pokes tab
(`app/FriendCal/Views/Shell/AppTabView.swift:46` is a stub). Home's Poke button is an honest stub
today: impact haptic plus a toast (`app/FriendCal/Views/Home/ActionRow.swift:5`). Note: that comment
cites "(D20)", but issue #5's D20 is the heatmap-vs-busy TODO above (see `TODOS.md` "Heatmap vs. Busy
blocks"). Two decisions share the ID; the code comment's number is the stale one. Fix the comment
when this is picked up.

**Why:** design doc premise 6 — a lightweight nudge replacing "@ them and tag three times" in the
iMessage thread (`docs/designs/friendcal-hub.md:27`). Rate limit and mute are already decided:
1 per (from, to, proposal) per 24h, mute per user (`docs/DECISIONS.md:7`), and `PokeService`
(`app/FriendCal/Services/PokeService.swift`) already implements both, with `ProposalTests.swift:185`
as its only caller.

**Context:** Deferred by the 2026-11-07 /plan-ceo-review (decision D5), which approved **only**
Poke's design session. **Deferral reason:** the delivery half needs APNs, which needs the Apple
Developer Program membership that was pending verification on 2026-11-07 — the same blocker that
gates Sign in with Apple. Building the in-app half alone ships a feature whose entire value is
out-of-app. Issue #5 D17 deleted `recordPoke` from the service layer, so that is a deliberate
re-add when this is picked up.

**Effort:** L
**Priority:** P2
**Depends on:** An active Apple Developer Program membership (APNs key); **Poke's UX design session**
(approved separately on 2026-11-07, resolving the Hold on who can poke whom, what the recipient
sees, where mute and the rate limit surface, and what a poke looks like with notifications off).

## Sign-in

### Apple server-to-server notifications for revoked credentials

**What:** Register a notification endpoint on the Services ID and handle Apple's server-to-server
events, at minimum `consent-revoked` and `account-delete`, so the backend learns when someone
removes FriendCal from their Apple ID or deletes their Apple ID entirely. On receipt, mark the
local identity inactive so the next launch returns to the sign-in gate instead of presenting a
signed-in app backed by a dead credential.

**Why:** Apple's 5.1.1(v) reference tells Sign in with Apple apps to revoke user tokens on account
deletion *and* to use server-to-server notification endpoints to handle changes to those accounts
(`developer.apple.com/support/offering-account-deletion-in-your-app/`). Without the endpoint, a
person who revokes access in Settings stays signed in on-device and the backend never finds out.

**Context:** Found by the 2026-11-07 /plan-design-review while verifying Codex's finding that the
deletion flow owes Apple more than a row delete. Design review issue 7A writes the revocation call
itself this wave (unexercised, Apple-blocked) and shows a Settings fallback line on the deletion
receipt whenever revocation cannot run; this TODO is the other half. Issue 2J already persists the
authorization code at sign-in, which is the prerequisite the revocation call needs.

**Amended 2026-11-07 (CEO re-cost, decision D2).** This entry now owns the **whole** revocation
chain, not just the notification endpoint: the `/auth/token` exchange, refresh-token custody,
`/auth/revoke`, and this endpoint. Design review 7A's plan to write the call this wave was withdrawn
by the eng delta's D7 — Apple's authorization code is single-use and expires in five minutes, so
issue 2J's persisted code cannot reach deletion time, and the exchange needs a team-signed client
secret that must never ship in the app. Nothing is persisted for revocation this wave and the
deletion receipt's Settings line renders unconditionally.

**Also resolve here, before submission:** whether CEO D8's retention of the departing person's
**holds and attendee membership** is compatible with 5.1.1(v)'s coverage of the account "along with
their personal data", or whether only the display name may survive. Raised by the Codex outside voice
on 2026-11-07 and folded into this entry; the deletion semantics were reviewed for identity removal
and token revocation, never for retention. Re-read the current guideline wording first — the sources
on file date from the 2022 rollout.

**Effort:** M
**Priority:** P2
**Trigger: blocks first App Store submission.** (Changed 2026-11-07 from "when the membership lands";
a membership arriving is not an event that makes anyone open TODOS.md, whereas a submission gate is.)
**Depends on:** An active Apple Developer Program membership (Services ID + team key); a reachable
HTTPS endpoint, so it also depends on having any server-side deployment at all.

## Me

### Release a hold from My commitments

**What:** A swipe action on a commitment row that calls `release(slotID:)`
(`app/FriendCal/Services/ProposalStore.swift:88`), with a confirmation naming the plan the hold
belongs to, plus its in-flight and failure states.

**Why:** The store method already exists, and My commitments is where a person notices a hold they
want to drop. Today the screen sends them elsewhere: design review issue 1F added the line "Change
a hold on its plan." precisely because the row refuses the gesture.

**Context:** Deferred by the 2026-11-07 /plan-design-review (issue 1F) under CEO D6, which scoped
Lane 3 read-only. Read-only was a deliberate scope call, not an oversight — recorded here so the
next person to touch the screen knows that. Issue 1F also forbids chevrons, swipe actions and
button traits on commitment rows, so picking this up means amending that prohibition, not working
around it. The row ordering rule (issue 1D) must survive a release without the list jumping.

**Effort:** S
**Priority:** P3
**Depends on:** None.

## Completed

### Snap lock window bounds to whole minutes before wiring lockProposal

Done in issue #5 PR1 (decision D18): `ProposalService.validateLock(cell:duration:)` rounds the window start down and the end up to whole minutes, and `AvailabilityService.promoteToBusy` judges coverage at minute granularity; `ProposalTests.testValidateLockSnapsToWholeMinutesAndMicrosecondHoldPromotes` locks a window whose common start carries microseconds. Original note: 2026-11-06 /ship (a-2e165bc43fc4, finding 1).
