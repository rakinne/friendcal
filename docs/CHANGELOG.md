# Changelog

## 2026-11-04 — Init

- Created `friendcal` repo and tracking structure
- Ready to scaffold app source in `app/`

## 2026-11-05 — Kinetic Warmth design system

### Added
- Kinetic Warmth DESIGN.md — warm paper, ember pulse, myFaves wheel + heatmap hero; Variant A approved
- myFaves wheel as nav + identity (10-cap orbit, stealth-aware)
- Brunch overlap heatmap with Live + best badge, Poke/Share actions

### Changed
- AGENTS.md now guards DESIGN.md as visual source of truth

## 2026-11-06 — Issue #5 PR1: the recipient loop on the in-memory store

### Added
- `ProposalStore` protocol and `InMemoryProposalStore` (fixture-seeded; mirrors lock_proposal / join_proposal rules, codes and `FC_*` hints), `LockState`, `ProposalDraft`, `DeepLink` (`friendcal://proposal/<id>`), `UserFacingError`, `DateText`
- Locked Invite as a live state: card with scrim and badge, per-state caption and controls, availability sheet (mark mode, past cells quiet, 44pt cells), lock sheet (durations, "All", inline refusals), Invites list with order and empty/error states, create sheet with a success step and share link, Edit plan
- `ProposalSession` (HomeModel widened): toggle holds, server-first lock, join, edit, store snapshots, one-shot lock acknowledgment; `ProposalListModel`
- Fixtures: lockedInvite, lockedInviteCreator, shortOverlap, creatorAlone, lockedPlan, lockedWithoutYou, lockedLateJoiner, invites; `-FriendCalNow`, `-FriendCalFailNext`, `-FriendCalStoreLatency`
- `Proposal.expectedCount`, `lockedAttendeeIDs`, `postLockRecipientIDs`, `lockedAt`; `HeatmapBuilder.weeks(expectedCount:)`; `ProposalService.validateLock(cell:duration:)` with minute snapping; `Typography.hero`

### Changed
- Home: heatmap header links to the invite, Request times opens the create sheet, DEMO badge in the header row, locked cell pill and "in" chips, Share names the locked plan
- Invites tab is a list (testStubTabs now covers Groups, Pokes, Me)
- The share link opens on the same phone only until PR2 wires Supabase

### Removed
- `DebugProposalModel`, `MockSupabaseService`, `Proposal.friendsgivemasPreview`, `ProposalService.createProposal`, `PokeService.recordPoke`

