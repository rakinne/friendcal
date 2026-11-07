# Changelog

All notable changes to FriendCal are listed here, newest first. The version lives in `VERSION`.

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
