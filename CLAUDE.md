# CLAUDE.md
## Skill routing
When the user's request matches an available skill, invoke it via the Skill tool. Route only to skills in the session's available-skills list; answer directly for quick questions or small scoped edits.
Key routing rules:
- Product ideas/brainstorming → invoke /office-hours
- Strategy/scope → invoke /plan-ceo-review
- Architecture → invoke /plan-eng-review
- Design system/plan review → invoke /design-consultation or /plan-design-review
- Full review pipeline → invoke /autoplan
- Bugs/errors → invoke /investigate
- QA/testing site behavior → invoke /qa or /qa-only
- Code review/diff check → invoke /review
- Visual polish → invoke /design-review
- Ship/deploy/PR → invoke /ship or /land-and-deploy
- Save progress → invoke /context-save
- Resume context → invoke /context-restore
- Author a backlog-ready spec/issue → invoke /spec

## Testing
Run all four lanes from the repo root (chosen in /ship, 2026-11-06):
- core: `cd app && swift test --scratch-path "$HOME/Library/Caches/friendcal-spm"` (FriendCalCore package tests, ~10s). The scratch path keeps SwiftPM output out of iCloud-synced `~/Documents`: a relinked test bundle there picks up Finder xattrs and CodeSign fails with "resource fork, Finder information, or similar detritus not allowed".
- sql: `scripts/test-sql.sh` (supabase/tests/*_test.sql against a throwaway local Postgres 15+, ~20s; set PG_BIN if Postgres is not under /opt/homebrew/opt). 15 is a hard floor, not a preference: the stealth boundary depends on `security_invoker` views, which do not exist on 14. Each test file runs in its own database, against both a fresh schema and one upgraded from `origin/main` with rows already present. RLS assertions must go through the `t.*` helpers in `supabase/tests/helpers.sql` — the harness connects as a superuser, which bypasses RLS, so a bare `select count(*)` passes against a deny-all policy.
- site: `node --test site/test/landing.test.mjs` (the friendcal.app landing pages and the apple-app-site-association file; Node 20+, no install step, ~1s).
- ios: `cd app && xcodebuild test -project FriendCal.xcodeproj -scheme FriendCal -destination 'platform=iOS Simulator,name=iPhone 17'` (app + UI tests). The 44pt grid tests (`HomeUITests/testAllColumnsFitInsideCard`, `LockedInviteUITests/testMarkModeCellsAreAtLeast44pt`, `LockedInviteUITests/testLockSheetDurationSegmentsAreAtLeast44pt`) also run on `name=iPhone SE (3rd generation)`.

UI tests pick their state with launch arguments: `-FriendCalFixture <scenario>` (FixtureScenario), `-FriendCalStore memory` (the in-memory store; the only store until #5 PR2), `-FriendCalNow 2026-11-10T12:00` (pins the clock, local calendar), `-FriendCalToastSeconds <n>`, `-FriendCalFailNext <operation>` (one store operation fails once), `-FriendCalStoreLatency <seconds>`, `-FriendCalSearch fixture` (the deterministic Austin place and city search instead of MapKit; UI tests that touch search always pass it), `-FriendCalSearchFailNext throttled|offline|noResult|outsideArea` (the next search or resolve fails once), `-FriendCalStaleNext vetoed|locked|removed` (the host's veto, the lock, or the suggester's withdrawal lands on the in-memory store unseen just before the viewer's next vote, so the vote meets the real refusal and the screen must reconcile), `-FriendCalTab home|groups|pokes|invites|me` (opens that tab), `-FriendCalGroups crew|friends|alone` (the Groups state: the approved crew, friends with no crew yet, or no friends), `-FriendCalTagAlong plan` (Leo hosts a locked "Tacos" plan you were sent and are not in), `-FriendCalPokes inbox` (pokes already waiting when the app opens), `-FriendCalPushTap poke/<uuid>|tagalong/<uuid>` (stands in for tapping a push), `-FriendCalLastCity none|'Austin, TX|30.2672|-97.7431'` (pins the remembered city that New plan prefills; without it a persisted value leaks between UI test runs. The shape is name|lat|lon, not JSON, because UserDefaults silently drops a launch value that looks like JSON). `-FriendCalFriendLink valid|dead|own|already` (what the in-memory store answers for ANY opened friend-link token: valid names Sam as the inviter, and a second accept reads already), `-FriendCalPendingLink none|stored|<url>` (pins the stored pending link: `none` starts with nothing pending and clears it, a URL pins that link, `stored` restores whatever the last launch left, which is how a relaunch is tested; with no argument a demo or UI-test launch starts clean so one test's link cannot leak into the next), `-FriendCalSignedOut 1` (the fixture's data with nobody signed in, so the sign-in gate shows and a pending link can be seen behind it), and `-FriendCalFailNext` also takes `friendLink`, `resetFriendLink`, `previewFriendLink`, `acceptFriendLink`, `friends` and `removeFriend`. Until the entry points ship (PR 3) the Add a friend sheet opens from the debug sheet: long-press the Home wordmark, then "Add a friend" (`debug.addFriend`); `debug.friendJoins` (in-memory store only) makes "Jess" open your link on another phone.

`app/FriendCal.xcodeproj` is tracked and generated from `app/project.yml`: after adding or removing files run `cd app && xcodegen generate` and commit the project diff.

## Releasing to TestFlight
Run `scripts/testflight.sh` from the repo root to put the latest build on TestFlight (set up 2026-11-09). It bumps `CURRENT_PROJECT_VERSION` in `app/project.yml`, regenerates the project, archives, and uploads to App Store Connect. Commit the bump afterwards: App Store Connect rejects a build number it has already seen for the same `MARKETING_VERSION`. Pass `--no-bump` to retry a failed upload without bumping. Processing takes 5-15 min, then the build appears in TestFlight.
- Identity: bundle ID `com.friendcal.app` is permanent (registered in App Store Connect). Team ID `6589A6M74D` (paid program; the same ID as the earlier Personal Team).
- Signing is automatic. Each machine needs the gitignored `app/Config/Local.xcconfig` with `DEVELOPMENT_TEAM = 6589A6M74D` (copy `Local.xcconfig.example`), Xcode signed in to the paid Apple ID, and fonts from `scripts/fetch-fonts.sh`. The export step creates the Apple Distribution cert and profile on first use (`-allowProvisioningUpdates`).
- The app icon is a generated placeholder ("FC" on the accent color, `AppIcon-1024.png`). Replace the PNG with the real one: 1024x1024, opaque, no rounded corners.
- `ITSAppUsesNonExemptEncryption` is `false` in `project.yml` (HTTPS only). Revisit it if the app ever ships its own cryptography.
- External testers need Apple's one-time Beta App Review; internal testers get builds right away.
