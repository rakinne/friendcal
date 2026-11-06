# TODOS

## Home

### "What changed since last visit" cue on Home

**What:** On a return visit, highlight what changed since the user last opened Home: a one-time coral blink on newly free friends' faces, and/or a "+N since yesterday" note on the best heatmap cell.

**Why:** The design doc's success metric is daily wheel opens without a pending proposal. Today a return visit looks identical unless the user notices a changed number.

**Context:** Raised in the 2026-11-06 /plan-design-review of issue #4 (journey storyboard step 8, decision D37). Home is fixture-only in #4, so there's no real change data. Respect DESIGN.md motion (one authored moment, Reduce Motion falls back to color only) and D23 (only the active arc pulses continuously). Start from the LIVE single-pulse-on-change behavior in D23.

**Effort:** M
**Priority:** P3
**Depends on:** Supabase Realtime wiring for Home (out of scope in #4), plus a persisted "last seen" timestamp per user.
