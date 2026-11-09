# Changelog

All notable changes to FriendCal are listed here, newest first. The version lives in `VERSION`.

## [0.3.0.0] - 2026-11-08

### Added
- Choose a city for your plan. New plan now asks for a city, starts from the one you used last time, and the plan's Places section lets the host pick or change it.
- Suggest places from the plan screen. Search near the plan's city, tap a result to add it, and see who already suggested it. If someone suggested the same place, you can vote for theirs instead.
- Vote, pass on and bring back places from a full list. The host can pass on a place and bring it back, and you can take your vote back or withdraw a place you suggested. Each action tells you what happened, and a failed one shows a message.
- Clear messages when a search can't finish. You see whether you searched too fast, lost your connection, found nothing, or picked a place outside the city.

### Changed
- The host can now change a plan's city after friends have marked times. The dates stay frozen, so changing the dates is still refused.
- Signing out or deleting your account forgets the remembered city, so the next person on the phone doesn't start with yours.

## [0.2.0.0] - 2026-11-08

### Added
- A new welcome screen when you open the app. It asks only for your name and, if you came from an invite link, tells you which plan you were invited to.
- Groundwork for choosing a place together on a plan. Screens for it come next. The server now keeps each plan's city and the places friends suggest, with one vote per person, a host veto, up to 2 places per friend and 10 per plan, and a winner that is picked and frozen when the plan locks: most votes first, then the earliest suggestion.
- Place search near the host's city with Apple Maps, kept to places within 25 km of the city. The 25 km limit is enforced in the app only.
- Suggesting, voting, passing on and withdrawing places work in the app's plan session with the same rules as the server, so previews and tests can walk through the whole flow. For now everything stays on this phone.

### Changed
- A plan can carry a city. The host can change it while the plan is collecting times but can't clear it, and it freezes once the plan locks.
- Deleting your account now removes your votes on plans that are still collecting, so a friend who left can't decide a winner. Your suggestions and your votes on locked plans stay.
- Errors on place actions, such as a full plan or a place the host passed on, now read as plain sentences.

### Fixed
- Someone who isn't on a plan can no longer add or vote on its places, even when the plan has no recipient list.
- When the host passes on a place, the friend who suggested it can no longer withdraw it to bring the same place back.
- Place names are compared exactly as the server compares them, so two spellings that only look alike are treated as different places in both.

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
