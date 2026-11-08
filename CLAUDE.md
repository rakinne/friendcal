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
Run all three lanes from the repo root (chosen in /ship, 2026-11-06):
- core: `cd app && swift test --scratch-path "$HOME/Library/Caches/friendcal-spm"` (FriendCalCore package tests, ~10s). The scratch path keeps SwiftPM output out of iCloud-synced `~/Documents`: a relinked test bundle there picks up Finder xattrs and CodeSign fails with "resource fork, Finder information, or similar detritus not allowed".
- sql: `scripts/test-sql.sh` (supabase/tests/*_test.sql against a throwaway local Postgres 15+, ~20s; set PG_BIN if Postgres is not under /opt/homebrew/opt). 15 is a hard floor, not a preference: the stealth boundary depends on `security_invoker` views, which do not exist on 14. Each test file runs in its own database, against both a fresh schema and one upgraded from `origin/main` with rows already present. RLS assertions must go through the `t.*` helpers in `supabase/tests/helpers.sql` — the harness connects as a superuser, which bypasses RLS, so a bare `select count(*)` passes against a deny-all policy.
- ios: `cd app && xcodebuild test -project FriendCal.xcodeproj -scheme FriendCal -destination 'platform=iOS Simulator,name=iPhone 17'` (app + UI tests). The 44pt grid tests (`HomeUITests/testAllColumnsFitInsideCard`, `LockedInviteUITests/testMarkModeCellsAreAtLeast44pt`) also run on `name=iPhone SE (3rd generation)`.

UI tests pick their state with launch arguments: `-FriendCalFixture <scenario>` (FixtureScenario), `-FriendCalStore memory` (the in-memory store; the only store until #5 PR2), `-FriendCalNow 2026-11-10T12:00` (pins the clock, local calendar), `-FriendCalToastSeconds <n>`, `-FriendCalFailNext <operation>` (one store operation fails once), `-FriendCalStoreLatency <seconds>`.

`app/FriendCal.xcodeproj` is tracked and generated from `app/project.yml`: after adding or removing files run `cd app && xcodegen generate` and commit the project diff.
