---
# gstack: design-md-format=spec
name: FriendCal
description: Warm, playful, low-pressure social planning — coral pulse over cream paper with an interconnected wheel
colors:
  primary: "#FF4E2E"
  on-primary: "#FFFFFF"
  background: "#FBF1E5"
  surface: "#FFF8EF"
  surface-2: "#FFF1E6"
  text: "#151515"
  text-muted: "#7A6C5F"
  accent: "#18A99A"
  accent-hover: "#0E6F68"
  accent-soft: "#E6F7F5"
  peach: "#F7C9A4"
  peach-light: "#FBE1C8"
  border: "#EADCCB"
  shadow: "#C9A98A"
  success: "#1A9E5C"
  warning: "#E8A317"
  error: "#E23D3D"
  error-text: "#C92A2A"
typography:
  display:
    fontFamily: "Cabinet Grotesk"
    fontWeight: 800
    fontSize: clamp(1.7rem, 5vw, 2.375rem)
    letterSpacing: "-0.02em"
  brand:
    fontFamily: "Cabinet Grotesk"
    fontWeight: 800
    fontSize: 1.625rem
    letterSpacing: "-0.01em"
  body:
    fontFamily: "Source Sans 3"
    fontSize: 1rem
    lineHeight: 1.55
  label:
    fontFamily: "Source Sans 3"
    fontSize: 0.75rem
    letterSpacing: 0.04em
  mono:
    fontFamily: "JetBrains Mono"
    fontFeature: tnum
rounded:
  sm: 6px
  md: 12px
  lg: 20px
  pill: 9999px
  full: 9999px
spacing:
  xs: 4px
  sm: 8px
  md: 16px
  lg: 24px
  xl: 32px
  2xl: 48px
components:
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.on-primary}"
    rounded: "{rounded.pill}"
  button-primary-hover:
    backgroundColor: "#E8431A"
  button-secondary:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.on-primary}"
    rounded: "{rounded.pill}"
  button-outline:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.accent-hover}"
    borderColor: "{colors.accent-hover}"
    rounded: "{rounded.pill}"
  card:
    backgroundColor: "{colors.surface}"
    rounded: "{rounded.lg}"
  input:
    borderColor: "{colors.border}"
    rounded: "{rounded.md}"
  nav-link:
    textColor: "{colors.text}"
---

# FriendCal

## Overview

**Creative North Star:** Kinetic Warmth — organic rounded geometry on warm paper, with a pulsing coral wheel and heatmap that makes interconnectedness visible at a glance.

**Product context:** Shared calendar for friend groups (not family/work). iOS SwiftUI Operate app, Supabase Realtime backend. Core loop: Request-for-Times → live heatmap → lock → generative invite art / Tag Along / Poke / Stealth. Hero surfaces are the **myFaves wheel** (10 cap + drawer) and the **availability heatmap**.

**Mode per surface:** Persuade (invite art cards, App Store) — warm + expressive; Operate (wheel, heatmap, Poke) — grid-disciplined + minimal fuss; Read (upcoming pokes, messages) — Source Sans 3 body; Experience (locked invite reveal) — morph choreography.

**Reference sites:** Partiful, Luma, Howbout, TimeTree, Apple Invites (visual research attempted; headless browser blocked by sandbox — proceeding with in-distribution knowledge + prior competitive read).

**Key characteristics:**
- Pulsing, not throbbing — ember coral is the only drenched hue
- Interconnected wheel reads as a social graph (orbit lines, online dots, connection arcs)
- Heatmap as the single source of truth — intensity = overlap, "best" badge is earned
- Minimal fuss — one-thumb Poke, stealth toggle, share-sheet native
- Invite art is generative, lock-gated — Partiful-like hype on event creation

## Colors

**Strategy:** Committed — warm cream #FBF1E5 owns the canvas; surfaces are card ivory #FFF8EF; ember coral #FF4E2E is the committed pulse for brand, primary Poke CTA, active wheel arcs, and heatmap peaks. Teal #18A99A is the calm secondary for Share, online dots, and Live indicator. Neutrals desaturate from the warm base so everything feels sunlit, not corporate.

Light mode only — use scene is daytime social planning on phone in varied lighting; light preserves warmth and heatmap legibility. Dark would mute the coral pulse and force inverted heat intensity.

Teal *text* ("online-ish", "LIVE") and the Share fill use accent-hover #0E6F68: teal #18A99A text is 2.6:1 on cream and 2.8:1 on ivory, so #18A99A stays for dots and non-text fills (D25). Muted text #7A6C5F is 4.55:1 on the cream canvas and 4.82:1 on ivory cards, so it's for captions and labels only, never on peach fills. Error text uses error-text #C92A2A (4.89:1 on cream, 5.18:1 on ivory); error #E23D3D is 3.79:1 on cream and 4.01:1 on ivory, so it is for fills and icons only, never a label.

Interaction signals: primary = coral fill + white text; secondary = teal; disabled = peach-light #FBE1C8; success/warning/error are semantic tints only. Hairline borders #EADCCB separate cards from the cream ground; soft warm shadow #C9A98A (8% opacity) lifts phones/cards without glow halos. Never use purple/violet gradients; never halo a dark surface.

## Typography

Cabinet Grotesk (Fontshare, verified 600/700/800) for display/brand — geometric with rounded terminals, warm, owns wheel labels and screen titles like "Sunday Brunch?" and "myFaves". Source Sans 3 (Google Fonts, 400/500/600) for body/UI — humanist, superb at 13-14px for availability chips and messages. JetBrains Mono (Google Fonts) for data — heatmap day/time labels, Poke timestamps, tabular counts via `tnum`. Scale is purposeful: brand 26-28px / hero 34-38px / section 16px / body 13-14px / captions 10-12px. **iOS** uses the D27 token table (`DesignTokens.Typography`, all scaling with Dynamic Type): wordmark Cabinet 800 28 (-0.01em), display Cabinet 800 26 (-0.02em), title and button Source Sans 3 Semibold 17, body Source Sans 3 Regular 15, label Semibold 13, caption Regular 12, mono JetBrains Mono Medium 12, badge Semibold 10. Fixed-geometry graphics stop growing: heatmap numerals and day headers and the wheel cap at xxxLarge (cells offer the Large Content Viewer), and avatar initials cap at the default size, since the name beside each avatar scales. All other text scales fully and the page scrolls. Loading: Fontshare CSS for Cabinet Grotesk, Google Fonts for Source Sans 3 + JetBrains Mono; system rounded fallback only.

## Layout

Breakpoints: mobile single-column feed (20px side margin) — header/brand row → large circular orbit (32px surrounding clearance) → availability card (7-col heatmap) → friend chips → two-col CTA row → stealth toggle → fixed bottom tab (44-52px touch targets). Desktop: left orbit + right heatmap, wide dashboard preserves same modules. Max content width 1100px, centered. Density: airy chrome, dense heatmap — contrast is the point. Intentional break: wheel bleeds slightly into header; heatmap header floats.

## Elevation & Depth

Depth from offset + soft blur, not zero-offset glow. Cards: 0 8px 24px rgba(201,169,138,0.12) over hairline border #EADCCB. Phones: 0 16px 48px rgba(0,0,0,0.08). No glow halos, no spotlight washes, no frosted-glass everywhere — one translucent layer only where a locked invite card needs depth.

## Shapes

Radius hierarchy: inner heatmap cells sm 6px, cards lg 20px, pills/toggles full 9999px. Nested inner radius = outer radius − gap (12px inner inside 20px outer). Wheel segments use 6px segment rounding; orbit guides are hairline dashed with 1px stroke. No nested cards, no bubbly same-radius everywhere.

## Components

**Poke (primary button):** coral #FF4E2E, pill, 52px height, white text + hand icon, hover #E8431A, active scale 0.98, disabled peach-light. Always dominant — one per screen.

**Share slot (secondary button):** accent-hover #0E6F68 fill (white text 6.0:1, D25), pill, same height, placed adjacent to Poke but visually quieter (1 : 1.38 width split, smaller icon). Shares the selected slot as "Brunch? Sat, Nov 14 · 10:00-11:30 AM works for 13 of 15" (date + common window + count). Disabled (peach-light) when nothing is selected or the selected cell has nobody in common.

**Heatmap:** 7-column grid (Mon–Sun) × Morning/Afternoon/Evening rows; rounded 6px cells; fill ramp peach-light #FBE1C8 → peach #F7C9A4 → coral-orange #FF6A32 → primary #FF4E2E for peak; numerals are always text #151515 (>= 5.5:1 on every ramp step); "best" is an ivory pill with a 1pt coral border on the cell's bottom edge, and the selected cell gets a 2pt text-color ring with a 2pt ivory gap (D26). Rings: selection ring = text (Home); my-hold ring = accent + a 16px accent circle with a white check at the cell's top-right (availability sheet, #5 5.1A). Three quiet looks: outside the window = dashed hairline; zero overlap = ivory, no numeral; already passed = surface-2, no numeral, not a control (availability sheet only, #5 5.2A). A locked plan's cell carries a primary "locked" pill in place of "best" (#5 2.2A). The availability sheet's grid drops the 52px gutter and puts each row's label ("Morning · 6a–12p") above its row so cells tile at >= 44px on every iPhone (#5 6.1A). The LIVE dot is solid teal and beats once (320ms) only when data changes; after 5 minutes it turns grey "Updated Nm ago".

**Friend chip:** compact pill with avatar 28px, name 13px, status dot + word in text color (green free / amber maybe / teal after N / grey busy) — never an icon-in-circle grid. "busy" means no slot marked for that time, so a manual hold, a hidden surprise plan and no reply look identical and stacked busy chips reveal nothing (X1).

**Stealth toggle:** teal track when on, grey when off; label "Stealth until you're ready" + info dot; RLS-backed sanitization keeps BusyBlockView identical styling for hidden viewers.

**Locked Invite card:** a 4:3 text-free illustration asset (`invite-card-brunch`, coral sun + teal foliage on cream; generative organic shapes, never text in the art) clipped at 20px with the hairline border and the card shadow; a flat 60% text-color scrim over the bottom 40% feathered in over the 15% above it (the art never carries text); hero headline Cabinet 800 34px (-0.02em, `hero` token) in on-primary inside the bottom 40% with 20px insets, with the state caption under it ("Locked until 1 more friend overlaps") or, once locked, the date (title) and window (mono); lock badge 32px primary circle with a white `lock.fill`, inset 12px top-right, becoming a success circle with a white check on lock (320ms crossfade, immediate under Reduce Motion). Text inside the card stops scaling at xxxLarge; the Large Content Viewer carries it. The app appends "?" to the title while requesting and drops it once locked (#5 2.1A). Below the card: one coral control (Invite friends for the creator alone, "Lock Sat afternoon" for the creator at quorum), the teal link "Unlock with availability" / "Update your availability", the muted progress line ("7 of 10 overlap so far", "8 of 10 are in"), and the "You're free Sat morning, Sat afternoon" line (#5 1.1A, 3.1A).

**Availability sheet:** `.large` sheet from the invite: "When are you free?" (display), helper line (body, muted), "Done" (title, accent-hover) top-right, the heatmap in mark mode with the week pager, chips for the last-tapped cell (crossfade 180ms), the lock caption pinned at the bottom with the padlock glyph; its own toast for a failed save (#5 1.4A, 1.5A).

**Lock sheet:** outcome first: "Lock Sat, Nov 14?" (display), segmented durations 1 h / 1.5 h / 2 h / 3 h (accent-hover tint; those longer than the shared span disabled; an "All · 1 h 20" segment when the span is not itself one of the four; default 2 h or the longest that fits), the resulting window in mono, who is in (28px avatar stack + "8 of 10 are in"), coral 52px "Lock it in", Cancel in the bar; a refusal stays inline under the button with Retry and a collapsed Details line (#5 5.3A, D22, 2.3A).

**Create sheet:** "New plan" (display); one ivory card of labeled inputs (label style above each, hairline-border inputs at 12px): Plan title (placeholder "Brunch"), From / To as date-only pickers snapped to day bounds, "How many people, counting you?" stepper with "Sets when the plan can lock." (default 8, min 2); Create disabled until valid; errors in `error` caption under the offending field; success step "Brunch is live" (display), window "Nov 9–22", the link in mono with a copy affordance, coral "Share invite", "Done" lands on the invite. Edit mode reuses it with the dates frozen once anyone has marked a time (#5 3.2A, 3.3A, 5.4A).

**Invites rows:** "Invites" in display on the cream canvas (no system large title); ivory cards at 20px with the hairline border, 20px side margins, 12px gaps, >= 64px tall: title, status line in muted caption ("3 of 10 joined · Nov 9–22"; "Locked · Sat, Nov 14 · 10:00–12:00" after a 6px primary dot), a "HOSTING" outline badge on plans the user created; order locked-upcoming, requesting, past (dimmed 60%); "+" (accent-hover, 44px) in the bar; empty state "No invites yet" + "Start a plan" (#5 1.6A, 1.7A, 7.2A).

**Outlined pill:** ivory surface fill, 1.5pt accent-hover border, accent-hover label (label 13 semibold, or button 17 when full-width), pill radius, 44px minimum height. It is the quieter sibling of the filled pills, used where a screen has no coral control or already has its one. Voted state: accent-hover fill with an on-primary label "Voted" and a check, so the state is text plus a glyph, never color alone. A limit replaces the control with a muted line; there is no disabled variant (#13 7.5A).

**Places section (invite):** "Where?" in display on the cream canvas after a 24px gap, a muted line under it ("Near Austin, TX · Voting closes when Sam locks the date"), one ivory leader card, then a full-width outlined "Suggest a place" pill. The card holds an outline badge (LEADING, TIED or YOURS, badge style), the place name in title with the Vote pill trailing, address and "Suggested by" in muted caption, up to 4 overlapping 28px faces plus +N with the voters' names in caption and the count in mono as one 44px control, a "Your vote" line, a hairline divider and a 44px "View all N places" row. No coral anywhere in the section. The full list is a large sheet: one ivory row card per place (at least 64px, 12px gaps), order frozen while open, a "Passed by host" section on surface-2 with a lasting accent-hover "Bring back" button, and a 44px ellipsis menu on rows the viewer can act on. A departed friend is a neutral person glyph in text-muted on surface-2. After the lock the section collapses to a winner row attached under the card (pin, name, address, "Open in Maps") and a "How the vote went" row. The invite card itself is unchanged (#13, docs/designs/friendcal-places.md).

**DEMO badge:** inside the group pill on the in-memory store: "DEMO" in badge style, text color, 1px warning outline, 20px tall (warning text on ivory is 2.05:1, so only the outline carries the hue); VoiceOver "demo data, not synced" (#5 D7). The sign-in gate and name prompt (#5 1.3A) arrive with the network store.

**Bottom nav:** iOS uses the native Liquid Glass `TabView` (Home `house`, Groups `person.2`, Pokes `hand.wave`, Invites `envelope`, Me `person.crop.circle`), active coral via tint; inactive items keep system glass styling instead of muted brown (D34). 44px min target.

## Do's and Don'ts

- Do: Use ember coral only for primary actions, active wheel arcs, and heatmap peak — keep it committed and rare enough to pulse.
- Do: Keep heatmap cells tinted by intensity alone; encode "best" with the badge, not a new hue.
- Do: Preserve the single-column rhythm on mobile — wheel, then heatmap, then CTAs — so scrolling tells the story of consensus.
- Do: Illustrate invites with generative organic shapes (sun, foliage) — never a stock photo placeholder or CSS-shape illustration.
- Do: Respect reduce-motion — scale pulse degrades to color-only when preferred.
- Don't: Introduce purple/violet/indigo gradients, dark-mode glows, or radial halos behind the hero.
- Don't: Center everything or use a 3-column feature grid with icon-in-colored-circle cards.
- Don't: Put a pill kicker above the hero headline — the headline carries its own weight.
- Don't: Use system-ui or -apple-system as the display face; Cabinet Grotesk owns headlines.
- Don't: Nest cards inside cards; cards are the only container level.

## Motion

- **Approach:** intentional. Exactly one continuous animation on Home: the coral active arc on the wheel (spring response 0.5, damping 0.82), off under Reduce Motion (D23). Everything else animates once, on change.
- **Easing:** enter ease-out exit ease-in move ease-in-out
- **Duration:** micro 80ms short 180ms medium 320ms long 550ms
- **The one authored moment:** Locking a time — the heatmap peak cell morphs into the invite art card via shared-element, wheel contracts to a success halo, confetti is minimal (three dots, not a shower). Wheel segments settle with spring (damping 0.82, no overshoot); heatmap cells stagger entrance 30ms; Realtime peak bumps to 1.02 scale then settles.

## Decisions Log
| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-11-08 | Place voting design review (#13): Places on the Invite screen | Layout B, a leader-first card with a View all list; Vote and Suggest as outlined pills with no coral in the section; voter names visible with faces capped at 4; voting closes at the date lock and the lock sheet names the place; the winner is a row under the card, not inside the scrim; a veto confirms its vote cost and undo is a lasting Bring back; a host-set city row in New plan; error-text for every error label with 44px Retry and Details; 26 decisions in docs/designs/friendcal-places.md |
| 2026-11-06 | Issue #5 design review: the Locked Invite as a live state | Role/state contract with one coral control per screen and the Lock control on the invite (1.1A); the card is one artifact, no page dots (1.2A); availability marking is a sheet with my-hold rings + checks, quiet past cells and row labels above rows for 44px cells (1.4A, 5.1A, 5.2A, 6.1A); "?" appended to the title while requesting (2.1A); every store failure maps to plain copy inline with Retry and Details (2.3A); a 60% scrim over the bottom 40% keeps on-primary text >= 4.5:1 over white art (4.1A, delta O4); 32px lock badge (5.5A); inclusive headcount "counting you" (3.3A); lock durations disabled past the span with an "All" segment (D22) |
| 2026-11-06 | iOS Home amendments from /plan-design-review and eng review run 2 | Share fill and teal text use accent-hover for AA (D25); iOS type table with body 15 (D27); chip "stealth" becomes "busy" = no slot marked (D35, X1); native glass tab bar, inactive system styling (D34); one continuous pulse, the active arc (D23); share copy names the date and common window (X9); wheel and avatar initials cap their text size (approved 2026-11-06) |
| 2026-11-05 | Initial design system created (Kinetic Warmth) | Created by /design-consultation from FriendCal brief: pulsing heatmap/wheel as signature, interconnectedness + minimal fuss, iOS SwiftUI + Supabase Realtime; approved mockup variant A extracted for tokens |
| 2026-11-04 | Backend Supabase chosen | See docs/DECISIONS.md D1 — RLS for stealth, Realtime for heatmap |
