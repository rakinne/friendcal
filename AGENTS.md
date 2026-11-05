# AGENTS.md — FriendCal

- This thread's project slug is `tes` (learnings: `~/.gstack/projects/tes/learnings.jsonl`)
- gstack source: `~/.claude/skills/gstack` (global-git v1.91.33.0)
- Prefer `exec` + `cat ~/.claude/skills/gstack/<skill>/SKILL.md` over `tool_search` first
- Refresh gstack: `cd ~/.claude/skills/gstack && ./setup --host codex --refresh-registered`

## Project: FriendCal

Shared calendar app for friends.

## Conventions

- Branch prefix: `codex/`
- Commit style: conventional commits preferred
- Keep `docs/` up to date for product decisions

## Design System
Read DESIGN.md before visual or UI work: it defines the fonts, colors, spacing, and
aesthetic direction. Ask the user before departing from it. When reviewing or QA-ing
UI, flag code that doesn't match DESIGN.md.
