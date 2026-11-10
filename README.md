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

Tests: see `## Testing` in CLAUDE.md (core, sql and ios lanes). The sql lane needs Postgres 15+.

Backend: in the Supabase SQL editor run `supabase/schema.sql`, then these in order:
`schema_additions.sql`, `lock_proposal.sql`, `rls.sql`, `users_auth.sql`, `join_proposal.sql`,
`commitments.sql`, `places.sql` and `social.sql`. Every file after `schema.sql` is idempotent, so on an existing
project re-run the ones that changed. Apply `places.sql` before anyone locks a plan: `lock_proposal()`
calls its winner rule. `scripts/test-sql.sh` loads the same order. A full runbook, including recovery
from a failed run, is tracked in `TODOS.md`.

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
└── supabase/          # schema.sql plus the idempotent wave files (schema_additions, lock_proposal,
                       #   rls, users_auth, join_proposal, commitments, places, social), tests/
```

## Workflow

- `main` is the source of truth
- Create feature branches: `codex/<feature-name>`
- Commit often with clear messages
