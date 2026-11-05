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

Interaction signals: primary = coral fill + white text; secondary = teal; disabled = peach-light #FBE1C8; success/warning/error are semantic tints only. Hairline borders #EADCCB separate cards from the cream ground; soft warm shadow #C9A98A (8% opacity) lifts phones/cards without glow halos. Never use purple/violet gradients; never halo a dark surface.

## Typography

Cabinet Grotesk (Fontshare, verified 600/700/800) for display/brand — geometric with rounded terminals, warm, owns wheel labels and screen titles like "Sunday Brunch?" and "myFaves". Source Sans 3 (Google Fonts, 400/500/600) for body/UI — humanist, superb at 13-14px for availability chips and messages. JetBrains Mono (Google Fonts) for data — heatmap day/time labels, Poke timestamps, tabular counts via `tnum`. Scale is purposeful: brand 26-28px / hero 34-38px / section 16px / body 13-14px / captions 10-12px. Loading: Fontshare CSS for Cabinet Grotesk, Google Fonts for Source Sans 3 + JetBrains Mono; system rounded fallback only.

## Layout

Breakpoints: mobile single-column feed (20px side margin) — header/brand row → large circular orbit (32px surrounding clearance) → availability card (7-col heatmap) → friend chips → two-col CTA row → stealth toggle → fixed bottom tab (44-52px touch targets). Desktop: left orbit + right heatmap, wide dashboard preserves same modules. Max content width 1100px, centered. Density: airy chrome, dense heatmap — contrast is the point. Intentional break: wheel bleeds slightly into header; heatmap header floats.

## Elevation & Depth

Depth from offset + soft blur, not zero-offset glow. Cards: 0 8px 24px rgba(201,169,138,0.12) over hairline border #EADCCB. Phones: 0 16px 48px rgba(0,0,0,0.08). No glow halos, no spotlight washes, no frosted-glass everywhere — one translucent layer only where a locked invite card needs depth.

## Shapes

Radius hierarchy: inner heatmap cells sm 6px, cards lg 20px, pills/toggles full 9999px. Nested inner radius = outer radius − gap (12px inner inside 20px outer). Wheel segments use 6px segment rounding; orbit guides are hairline dashed with 1px stroke. No nested cards, no bubbly same-radius everywhere.

## Components

**Poke (primary button):** coral #FF4E2E, pill, 52px height, white text + hand icon, hover #E8431A, active scale 0.98, disabled peach-light. Always dominant — one per screen.

**Share slot (secondary button):** teal #18A99A, pill, same height, white text, placed adjacent to Poke but visually quieter (40% fill weight illusion via smaller icon).

**Heatmap:** 7-column grid (Mon–Sun) × Morning/Afternoon/Evening rows; rounded 6px cells; fill ramp peach-light #FBE1C8 → peach #F7C9A4 → coral-orange #FF6A32 → primary #FF4E2E for peak; "best" chip is coral text on warm ground. Live dot pulses with teal.

**Friend chip:** compact pill with avatar 28px, name 13px, status dot (green free / amber maybe / teal after-12 / grey stealth) — never an icon-in-circle grid; status is background tint + dot.

**Stealth toggle:** teal track when on, grey when off; label "Stealth until you're ready" + info dot; RLS-backed sanitization keeps BusyBlockView identical styling for hidden viewers.

**Locked Invite card:** full-bleed illustration (coral sun + teal foliage), lock badge 24px coral circle, large stacked title 34px, unlock affordance teal link "Unlock with availability" with lock icon.

**Bottom nav:** 5-item icon-led bar (Home Groups Pokes Invites Me), active coral, inactive muted brown, 44px min target.

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

- **Approach:** intentional
- **Easing:** enter ease-out exit ease-in move ease-in-out
- **Duration:** micro 80ms short 180ms medium 320ms long 550ms
- **The one authored moment:** Locking a time — the heatmap peak cell morphs into the invite art card via shared-element, wheel contracts to a success halo, confetti is minimal (three dots, not a shower). Wheel segments settle with spring (damping 0.82, no overshoot); heatmap cells stagger entrance 30ms; Realtime peak bumps to 1.02 scale then settles.

## Decisions Log
| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-11-05 | Initial design system created (Kinetic Warmth) | Created by /design-consultation from FriendCal brief: pulsing heatmap/wheel as signature, interconnectedness + minimal fuss, iOS SwiftUI + Supabase Realtime; approved mockup variant A extracted for tokens |
| 2026-11-04 | Backend Supabase chosen | See docs/DECISIONS.md D1 — RLS for stealth, Realtime for heatmap |
