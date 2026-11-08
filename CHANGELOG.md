# Changelog

All notable changes to FriendCal are listed here, newest first. The version lives in `VERSION`.

## [0.2.0.0] - 2026-11-08

### Added
- Suggest places on a plan — add a place with a name and optional address, vote for your favorites, and veto one you can't do. The winner is picked when the plan locks, with deterministic tie-breaking.
- Search for places nearby — MapKit-backed search with debounced queries, recent-place memory, and a 25 km search area guard that mirrors the server check.
- Server rules for place voting — new `places.sql` guard (`friendcal_places_plan`), four client-callable functions (suggest, vote, veto, withdraw), and winner selection wired into `lock_proposal()`.
- Place board in the session — `PlaceBoard` model tracks suggestions, votes and vetoes per plan, with in-memory and Supabase-backed stores.
- Proposal session now carries places — fixtures, drafts and the session layer include place state so previews and tests can exercise the full flow.

### Changed
- Place-related error messages now surface as user-facing copy via `UserFacingError` (new `FC_*` hints for suggestion, vote and veto failures).
- `ProposalDraft` and `Proposal` carry place context; `TODOS.md` and `DESIGN.md` updated to reflect the places design.

## [0.1.1.0] - 2026-11-07

### Added
- "My Commitments" on the Me tab — your own holds and Busy blocks across all plans, read-only, with provenance and authorized titles via new `my_commitments(p_from)` RPC.
- Me surface: `AuthGateView`, `MeView`, `AccountDeletionView` with sign-out and Apple-withheld-name handling; only the ~60-line `ASAuthorizationController` hop remains Apple-gated.
- First SQL regression harness that actually tests privacy: `rls_test.sql`, `users_auth_test.sql`, `loop_test.sql` now load `rls.sql` in both fresh + upgraded modes with policy-count assertions.

### Changed
- Hardened Supabase RLS — the three `using(true)` leaks are closed: `proposals` and `availability_slots` are now row-scoped, `busy_blocks` keeps rows readable but revokes `hidden_from`/`source_proposal_id`/`event_id` from `authenticated` (so excluded viewers see a grey block, not a hole), and `events` is read-scoped via `stealth_excluded()` helper. `circles`/`circle_members` denied to `anon`.
- `delete_account()` RPC: deleting your account anonymizes your `users` row (`Deleted account`, cleared avatar, `deleted_at`), tombstones the auth identity, cancels your open plans, releases your `softHold`s, and keeps locked plans and their Busy blocks intact.

### Fixed
- `supabase-stubs.sql` now mirrors Supabase's table grants — previous harness gave `authenticated` zero table privileges, so `select hidden_from from busy_blocks` was permission-denied before any fix and the stealth P0 had zero coverage.
- `supabase/sql.yml` CI (Postgres 15) now exercises both fresh and upgraded loads.

## [0.1.0.0] - 2026-11-06

### Added
- Open an invite and see how close the group is to a plan. The card shows who has joined, how many friends overlap and a one-line caption for your role.
- Mark when you're free right from the invite. Tap a day-and-part-of-day cell to mark it and tap again to clear it. Past times stay quiet.
- Lock a time once enough friends overlap. The host picks 1, 1.5, 2 or 3 hours inside the shared window, and everyone sees the settled plan with a "You're in" line.
- Create a plan from Home with a title, dates and a headcount, then share its invite link. The host can change the title and headcount later, and the dates freeze once anyone has marked a time.
- An Invites tab lists your plans, hosting first, with loading, empty and error states. A `friendcal://` link opens a plan directly.
- A DEMO badge shows that plans live on this phone only until the network version ships.

### Changed
- The Home heatmap title opens the invite, and a locked plan shows its time and who is in.
- Lock times snap to whole minutes, so a friend's free time can no longer miss the window by a few seconds.
- The Invites tab is a real list instead of a placeholder.

### Fixed
- Tapping cells quickly on the availability sheet no longer risks a crash or a wrong "This plan is gone" message.
- Editing a plan after more friends joined than expected no longer blocks a title-only change.
- Closed plans and holds that aren't yours now get their own plain-language messages.
