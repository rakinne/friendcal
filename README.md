# FriendCal

Shared calendar for friends — plan together, stay in sync.

## Getting Started

iOS 18+ SwiftUI app with a Supabase backend (built and tested with Xcode 27).

```bash
# 1. Fonts: Cabinet Grotesk is gitignored (its license forbids a public repo),
#    so every clone fetches it. The script checks pinned SHA-256s.
scripts/fetch-fonts.sh

# 2. Open the app. The project is generated from app/project.yml: after adding or
#    removing files run `cd app && xcodegen generate` (brew install xcodegen).
open app/FriendCal.xcodeproj
```

Tests: see `## Testing` in CLAUDE.md (core, sql and ios lanes). The sql lane needs Postgres 14+.

Backend: run `supabase/schema.sql`, `supabase/rls.sql`, then `supabase/lock_proposal.sql` in the
Supabase SQL editor. On an existing project, run only `lock_proposal.sql` (it is idempotent).

## Structure

```
friendcal/
├── README.md
├── AGENTS.md          # AI assistant instructions
├── CLAUDE.md          # skill routing + test lanes (core, sql, ios)
├── DESIGN.md          # design system (Kinetic Warmth)
├── docs/              # product docs, specs, decisions
├── designs/           # approved mockups (variant-A.png)
├── app/               # iOS SwiftUI app; FriendCalCore SwiftPM package (Package.swift);
│                      #   FriendCal.xcodeproj generated from project.yml by XcodeGen
├── scripts/           # fetch-fonts.sh (SHA-256 pinned fonts), test-sql.sh (SQL test lane)
└── supabase/          # schema.sql, rls.sql, lock_proposal.sql (run after schema.sql,
                       #   or alone to upgrade), tests/
```

## Workflow

- `main` is the source of truth
- Create feature branches: `codex/<feature-name>`
- Commit often with clear messages
