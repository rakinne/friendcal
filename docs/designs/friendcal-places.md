# Places on the Invite screen: design decisions

Source: `/plan-design-review` of issue #13 on 2026-11-08, read against epic #10 (product rules R1 to R11, locked) and issue #14 (UI). The owner individually approved 26 decisions in that review, chose Layout B from three mockups, and approved five state pictures on a board. Text marked **Proposed** was derived from an approved decision and still needs the owner's sign-off on #13. This document replaces #13's checklist: it decides how R1 to R11 look and changes none of them.

## Approved Mockups

| Screen | Path | Direction | Notes |
|---|---|---|---|
| Layout choice | `/Users/rakinnefoote/.gstack/projects/friendcal/designs/invite-places-requesting-20261107/m-b/responsive-mobile.png` | Layout B, leader first | Chosen from three. Superseded in detail by the main-screen picture below. |
| Main screen, friend who voted for a non-leader | `/Users/rakinnefoote/.gstack/projects/friendcal/designs/places-states-20261107/main/responsive-mobile.png` | Decisions 1.1A, 1.2A, 1.5A, 1.6B applied | Generator artifact: card text is centered. The real card left-aligns it. |
| Host view at quorum | `/Users/rakinnefoote/.gstack/projects/friendcal/designs/places-states-20261107/host/responsive-mobile.png` | One coral Lock pill, ellipsis on the leader card | Generator artifact: card shows a food photo. The real card uses the illustration asset. |
| Tie | `/Users/rakinnefoote/.gstack/projects/friendcal/designs/places-states-20261107/tie/responsive-mobile.png` | TIED badge, tie-break line, tied place named | The picture adds the line "Cafe Lola was suggested first, so it wins a tie" (Proposed copy). |
| Places list, host, with a passed place | `/Users/rakinnefoote/.gstack/projects/friendcal/designs/places-states-20261107/list/responsive-mobile.png` | Voted, Vote, YOURS rows and a Passed by host section | Generator artifacts: the plus is drawn as a filled tile and the screen behind the sheet is invented. The spec is an unfilled deep teal plus icon. |
| Locked, winner row | `/Users/rakinnefoote/.gstack/projects/friendcal/designs/places-states-20261107/locked/responsive-mobile.png` | Winner row attached under the card | |

## How R8 is read

R8 says the winner "shows on the locked card" and that "if no place won, nothing shows". Decision 1.4A reads the first clause as the locked invite, with the winner row attached directly under the card. It reads the second clause as the card and the share text only, so a plan whose places exist but none won says "No place was picked." in the section. The owner chose this reading over the strict one. `InviteCard` is unchanged.

## Decisions

Each PL item lists the decision IDs that settled it. Decision IDs are in the register at the end of this section.

| ID | Decision |
|---|---|
| PL-1 Placement and visibility | Places is a section below the availability link, the free line and the progress line, after a 24pt gap. Heading "Where?" in `display`. One muted line under it: "Near Austin, TX · Voting closes when Sam locks the date" (host: "when you lock"). Shown in all three lock states; the creator alone sees it too. On iPhone SE it starts at the bottom edge of the first screen, so it is reached by scrolling. (1.5A, 1.6B, picture approval) |
| PL-2 Row anatomy | **Leader card:** badge, name with the Vote pill trailing, address, "Suggested by Maya", one 44pt row of up to 4 faces plus a `+N` pill, a names line and the count, then a "Your vote" line when the viewer voted, a divider, and a "View all N places" row. **List rows:** same anatomy as their own cards, ordered by votes, a YOURS badge and no Vote pill on the viewer's own place, an ellipsis menu on rows the viewer can act on. **Passed rows:** under "Passed by host", muted, visible to everyone. **Departed friend:** a neutral person glyph on `surface2`, named "A friend". (1.1A, 1.2A, 2.1A, 2.3A, 5.3A) |
| PL-3 Voting interaction | Tap Vote to vote. Tap Voted to remove the vote (toast "Vote removed"). Tap Vote on another place to move it (toast "Moved your vote to Bluebonnet Diner"). The Voted state is text plus a check, never color alone. A vote cleared by a veto or withdraw gets no notice: Vote buttons simply return. (6.2A, 2.4B) |
| PL-4 Search | Opens as a sheet from the main screen and is pushed inside the places list from its plus button (one sheet at a time). Field prompt "Search places near Austin, TX", caption "Within 25 km of Austin, TX". Under 2 letters: "Type at least 2 letters". A tapped result shows a spinner on its own row and the other rows dim. A duplicate shows an inline panel in the same sheet, never a second sheet. Success closes the sheet and shows the toast "Added Juniper Table". (1.5A, 2.2A, 2.6B, 7.1A, 7.2A) |
| PL-5 Host city | A "City" row directly under Plan title in New plan, pushed inside the sheet, with the caption "So friends can suggest places nearby." and the host's last-used city prefilled. Edit plan keeps the row enabled when dates are frozen, with the caption "Places already suggested stay." when places exist. A plan with no city: the host sees a row with an outlined "Choose a city" pill that opens Edit plan with the picker pushed. Friends see one muted line, "Places open once Sam picks a city." A locked plan with no city shows nothing. The city can be replaced, never cleared. (3.1A, 2.7A, 7.3A) |
| PL-6 Host and suggester actions | A 44pt ellipsis menu per row. The host sees "Pass on this place". The suggester sees "Withdraw my place". No swipe. A veto asks first and names the cost: "Pass on Cafe Lola? Its 4 votes are cleared and those friends can vote again." Undo is a lasting "Bring back" button on the passed row, with the note "Comes back with 0 votes". It is not a toast. (2.3A) |
| PL-7 Winner | After the lock, the section collapses to a winner row attached under the card: pin, name, address, and a 44pt "Open in Maps". Below it a "How the vote went" row opens a read-only list. If places existed and none won, the row is absent and a muted line says "No place was picked." The winner row and the collapsed section fade in during the existing 320ms lock crossfade with the existing success haptic, instant under Reduce Motion. The locked share text keeps its default suffix " at <name>". (1.4A, 3.2A) |
| PL-8 Copy | The table in the Copy section. |
| PL-9 Accessibility and layout | Three VoiceOver stops on the leader card. Height follows content. At accessibility text sizes, or when the name wraps on iPhone SE, the Vote pill moves below the details at full width. The list sort is frozen while a sheet is open. (6.1A, 6.2A, 2.5A) |
| PL-10 Tokens and contrast | One new component, the outlined pill. One token documented, `error-text`. Zero new color tokens. The inline error and the form field error switch to `error-text` with 44pt Retry and Details. (5.1A, 5.2A) |
| PL-11 Lock sheet (added by this review) | A "Place" row under the window: "Place: Cafe Lola, 4 votes", "Tied. Cafe Lola wins, suggested first.", or "No place yet. Voting closes when you lock." Plus the muted line "Locking also closes place voting." The sheet's duration segments are raised from 36pt to 44pt. (1.3A, TODO 2) |

Also decided: stale errors reconcile the screen instead of only showing text (2.8A). A suggest control is replaced by a muted line when a cap is reached (7.5A). Five more states are depicted as pictures and the rest are described here (7.4A).

### Decision register

| ID | Decision | Option |
|---|---|---|
| 1.1 | Explicit "View all N places" row plus a "Your vote" line | A |
| 1.2 | Suggested-by line, faces plus names, one tap to Who voted | A |
| 1.3 | Lock sheet shows the projected place and the closing line | A |
| 1.4 | Winner row under the card, how-the-vote-went, no-winner line | A |
| 1.5 | One header line with city and voting deadline; search repeats the radius | A |
| 1.6 | Suggest a place is a second outlined pill | B (not the recommendation) |
| 2.1 | Four explicit leader-card variants | A |
| 2.2 | Reuse the existing toast on the Invite screen | A |
| 2.3 | Menu, vote-count confirmation, lasting Bring back, passed rows visible | A |
| 2.4 | No notice when a vote is cleared | B (not the recommendation) |
| 2.5 | Freeze list order while open, update in place | A |
| 2.6 | Inline duplicate panel in the search sheet | B (the recommendation) |
| 2.7 | Host row and friend line on no-city plans | A |
| 2.8 | Reconcile on stale errors, word errors per action | A |
| 3.1 | City row under title, reason caption, last city prefilled | A |
| 3.2 | Winner takes part in the existing lock crossfade | A |
| 5.1 | Fix the shared error text color and 44pt targets | A |
| 5.2 | Add the outlined pill to DESIGN.md | A |
| 5.3 | Neutral glyph for a departed friend | A |
| 6.1 | Content-driven height, Vote moves below at large text | A |
| 6.2 | Tap Voted removes the vote, three VoiceOver stops | A |
| 7.1 | Search prompt, two-letter hint, spinner on the tapped row | A |
| 7.2 | Plus button in the list toolbar pushes search | A |
| 7.3 | Caption under the city row, no dialog | A |
| 7.4 | Updated main screen plus four states, rest described | A |
| 7.5 | Muted line replaces the Suggest pill at a cap | A |
| 7.5 | Muted line replaces the Suggest pill at a cap | A |

Two accepted gaps are on purpose and documented, not defects. Decision 1.6B leaves two outlined pills in the section, so the Vote pill stays small inside the card and Suggest is full-width below it, to separate them by size and position. Decision 2.4B means a voter whose vote was cleared while they were not watching gets no explanation, because the server keeps no history.

## Screen structure

```
FRIEND, collecting                                          taps lead to
nav: Locked Invite                                      ...
[ invite card ]
Update your availability                                 >  availability sheet
You're free Sat morning
             7 of 10 overlap so far
                                              24pt gap
Where?
Near Austin, TX . Voting closes when Sam locks the date
+----------------------------------------------------+
| LEADING                                            |
| Cafe Lola                               [ Vote ]   |  vote / Voted
| 2108 E Cesar Chavez St                             |
| Suggested by Maya                                  |
| (S)(P)(J)(D)  Sam, Pia, Jo and Dev       4 votes   |  Who voted list
| (check) Your vote: Bluebonnet Diner                |
| ------------------------------------------------   |
| View all 4 places                              >   |  places list sheet
+----------------------------------------------------+
[ + Suggest a place ]                                    search sheet

HOST differences: one coral "Lock Sat afternoon" pill above the
availability link; "...when you lock"; ellipsis on rows (Pass on this place).

PLACES LIST SHEET (large)        SEARCH (sheet or pushed in the list)
Done     Places        [+]       < Back   Search places near Austin, TX
Near Austin, TX                  Within 25 km of Austin, TX
[row] [row] [row]                results, or "Type at least 2 letters",
Passed by host                   or the inline duplicate panel
[passed row  Bring back]

LOCKED
[ invite card: Brunch / Sat, Nov 14 / 12:00-2:00 PM ]
[ pin  Cafe Lola, address                Open in Maps ]
( green dot ) You're in
              8 of 10 are in
How the vote went                                        >  read-only list
```

## Interaction states

```
FEATURE        | LOADING            | EMPTY                  | ERROR                  | SUCCESS               | PARTIAL
---------------|--------------------|------------------------|------------------------|-----------------------|--------------------------
Leader card    | skeleton card,     | no places: heading,    | inline error under the | pill fills with check,| zero votes: no badge,
               | invite capsules    | subline, "No places    | card, error-text,      | count +1, VoiceOver   | "No votes yet". Tie:
               |                    | yet. Suggest where to  | Retry 44pt. Stale      | announces             | TIED badge + tie line.
               |                    | go." and the Suggest   | errors reconcile (2.8) |                       | Own place leads: YOURS,
               |                    | pill, no empty card    |                        |                       | no Vote pill
Places list    | skeleton rows      | not reachable: the     | inline at the top of   | counts and names      | Passed by host section;
sheet          |                    | row is hidden at zero  | the sheet              | update in place,      | rows keep frozen order
               |                    | places                 |                        | order frozen (2.5)    |
Search         | spinner on the     | prompt + "Type at      | throttled, offline,    | sheet closes, toast   | duplicate panel: Vote,
               | tapped row, others | least 2 letters"       | no result, outside     | "Added <name>"        | or "You already
               | dim                |                        | area, shown in sheet   |                       | suggested this", or
               |                    |                        |                        |                       | "The host passed on this"
City row and   | picker shows a     | "Choose a city"        | no city found, offline | city name + chevron   | no-city plan (2.7);
picker         | spinner            |                        |                        |                       | Edit caption (7.3)
Lock sheet     | n/a                | "No place yet. Voting  | refusal inline,        | "Place: <name>, N     | tie wording (1.3A)
place row      |                    | closes when you lock." | existing pattern       | votes"                |
Winner row     | n/a                | none won: "No place    | n/a                    | pin, name, address,   | departed voter shows
and history    |                    | was picked."           |                        | Open in Maps          | the neutral glyph
Cap reached    | n/a                | the Suggest pill is    | n/a                    | pill returns when     | personal cap vs plan cap
               |                    | replaced by a muted    |                        | below the cap         | each have their own line
               |                    | line (7.5A)            |                        |                       |
```

One state is **Proposed**: with exactly one place and no passed places, the "View all" row is hidden because there is nothing more to see.

## Copy

**Approved verbatim** (inside an option the owner approved):

| Where | Text |
|---|---|
| Heading and subline | "Where?" / "Near Austin, TX · Voting closes when Sam locks the date" / host: "... when you lock" |
| Search | prompt "Search places near Austin, TX"; caption "Within 25 km of Austin, TX"; "Type at least 2 letters" |
| Leader card | badges LEADING, TIED, YOURS; "No votes yet"; "View all 4 places"; "Your vote: Bluebonnet Diner"; "Suggest a place"; "Voted" |
| Lock sheet | "Place: Cafe Lola, 4 votes"; "Tied. Cafe Lola wins, suggested first."; "No place yet. Voting closes when you lock."; "Locking also closes place voting." |
| Veto | "Pass on Cafe Lola? Its 4 votes are cleared and those friends can vote again."; "Passed by host"; "Bring back"; "Comes back with 0 votes" |
| Toasts | "Added Juniper Table"; "Vote removed"; "Moved your vote to Bluebonnet Diner" |
| VoiceOver | "Voted for Cafe Lola. Double tap to remove your vote." |
| Duplicate panel | "Already suggested by Maya" with a Vote button; "You already suggested this"; "The host passed on this" |
| City | "City"; "Choose a city"; "So friends can suggest places nearby."; "Places already suggested stay."; "Places open once Sam picks a city." |
| Caps | "You've suggested 2 places. Withdraw one to add another."; "This plan already has 10 places." |
| Winner | "Open in Maps"; "How the vote went"; "No place was picked." |

**Proposed** (derived from approved decisions, needs sign-off):

| Where | Text |
|---|---|
| Empty section | "No places yet. Suggest where to go." |
| Tie | "Cafe Lola was suggested first, so it wins a tie"; the View all subtext "Tied with Juniper Table, 2 votes" |
| Withdraw confirm | "Withdraw Juniper Table? Its 2 votes are cleared." Shown only when votes exist. |
| `FC_NO_AREA` | "Sam hasn't picked a city yet." |
| `FC_PLACE_LIMIT` | suggest: "You've suggested 2 places. Withdraw one to add another." Bring back: "Can't bring this back: Maya already has 2 places." |
| `FC_PLAN_FULL` | suggest: "This plan already has 10 places." Bring back: "Can't bring this back: the plan already has 10 places." |
| `FC_OWN_PLACE` | "You can't vote for your own suggestion." Defensive: the control is never offered. |
| `FC_VETOED` | on a vote: the row flips to Passed with "The host passed on this place." On suggest: "The host passed on that place." |
| `FC_BAD_PLACE` | "Couldn't save that place. Try another." |
| `FC_PLACE_NOT_FOUND` | "That place is gone." The row is removed on reload. |
| `FC_NOT_YOUR_PLACE` | "Only the person who suggested a place can withdraw it." |
| `FC_NOT_MEMBER` (place actions) | "Join this plan to suggest or vote." During an in-flight join, a read-only skeleton instead. |
| `FC_NOT_CREATOR` on a veto | "Only Sam can pass on a place." |
| `FC_LOCKED` on a place action | the screen reloads to the locked state with "This plan just locked. Voting is closed." |
| Network fallbacks | "Couldn't add that place. Retry." / "Couldn't save your vote. Retry." / "Couldn't update that place. Retry." / "Couldn't remove that place. Retry." |
| Search errors | throttled "Searching too fast. Wait a moment and try again."; offline "No connection. Check your internet and try again."; none "No places found near Austin, TX. Try another name."; outside area "That's outside Austin, TX. Try a place within 25 km." |
| City picker errors | "No city found. Try another name." / offline as above |
| Departed friend | "A friend" |

## Accessibility and responsive

**VoiceOver, leader card: three stops, in this order.**
1. Summary: "Leading place. Cafe Lola, 2108 E Cesar Chavez St, suggested by Maya." For the viewer's own place: "You suggested this."
2. Voters, one 44pt control: "4 votes from Sam, Pia, Jo and Dev. Double tap to see who voted." Individual avatars are hidden from VoiceOver.
3. Vote: "Vote for Cafe Lola." / "Voted for Cafe Lola. Double tap to remove your vote."

Other labels: "View all 4 places", "Your vote: Bluebonnet Diner", "Suggest a place", and for the winner row "Winner. Cafe Lola, 2108 E Cesar Chavez St. Open in Maps." Toasts announce through the existing announcement call.

**Identifiers go on leaf views only.** A container identifier overrides its children's in this codebase. Proposed names: `places.name`, `places.votes`, `places.vote`, `places.viewAll`, `places.suggest`, `places.menu`, `places.bringBack`, `places.search.field`, `places.search.result`, `places.duplicate.vote`, `places.winner.name`, `places.winner.maps`, `places.history`, `create.city`.

**Targets.** Every control is at least 44pt, including the ellipsis menu, the voters row, Bring back, Retry, Details and the lock sheet's duration segments.

**Responsive.** Height follows content, and the earlier "about 220pt" note is struck. By layout arithmetic from the code, about 520pt of an iPhone SE screen is used before Places starts, so the section is below the fold there. This is an estimate, not a measurement. At accessibility text sizes, or when the name wraps on iPhone SE, the Vote pill moves below the details at full width. The names line wraps to two lines, then "and N more". The subline wraps freely. Fixed-geometry graphics keep the existing caps and nothing else does.

**Reduce Motion.** The leader card crossfade (180ms) and the lock fade (320ms) are instant. No reorder animation exists, because the list order is frozen.

**Required frames at build time**: friend who voted, host, tie and locked, each on iPhone SE and at accessibility size 3.

## Contrast

Every ratio below was computed with the same math as `ContrastTests`: linearize sRGB, weights 0.2126, 0.7152 and 0.0722, ratio (lighter + 0.05) over (darker + 0.05). The instrument was checked first: black on white gives 21.00, text on primary gives 5.55 (the test's own anchor), and muted text gives 4.55 on cream and 4.82 on ivory as DESIGN.md documents. Warning on ivory prints 2.06 here against DESIGN.md's 2.05, a rounding difference.

| Pair | Ratio | Bar | In `ContrastTests` today |
|---|---|---|---|
| `text` on `surface` (place name, count) | 17.33 | 4.5 | yes |
| `textMuted` on `surface` (address, suggested by) | 4.82 | 4.5 | yes |
| `textMuted` on `background` (subline, Passed by host label) | 4.55 | 4.5 | yes |
| `accentHover` on `surface` (links, badges, Vote label) | 5.71 | 4.5 | yes |
| `accentHover` on `background` (Update your availability) | 5.39 | 4.5 | yes |
| `accentHover` on `surface` as an outline or check, non-text | 5.71 | 3.0 | yes |
| `onPrimary` on `accentHover` (Voted pill) | 6.01 | 4.5 | yes |
| `text` on `surface2` (passed row name) | 16.50 | 4.5 | yes |
| `textMuted` on `surface2` (passed row meta, departed glyph at 3.0) | 4.59 | 4.5 | **new row** |
| `accentHover` on `surface2` (Bring back) | 5.43 | 4.5 | **new row** |
| `errorText` on `background` | 4.89 | 4.5 | yes |
| `errorText` on `surface` | 5.18 | 4.5 | yes |
| `error` on `background`, fills and icons only | 3.79 | 3.0 | yes |
| `error` on `surface`, fills and icons only | 4.01 | 3.0 | yes |
| `surface` on `text` (toast) | 17.33 | 4.5 | yes |
| `onPrimary` on the 60% scrim over white (card text) | 4.77 | 4.5 | yes |
| `text` on the six face colors (initials) | 9.26, 9.78, 8.19, 8.13, 11.98, 9.36 | 4.5 | yes |

All pairs pass. Two rows need adding to `ContrastTests`: the two `surface2` pairs.

## Tokens and components

| Item | Decision |
|---|---|
| New component | **Outlined pill** (`button-outline`): `surface` fill, 1.5pt `accent-hover` border, `accent-hover` label, pill radius, 44pt minimum. Voted state: `accent-hover` fill, `on-primary` label "Voted" with a check. Added to DESIGN.md. |
| New avatar variant | Departed friend: neutral person glyph in `text-muted` on `surface-2` with a hairline border. VoiceOver "A friend". |
| Token documented | `error-text` #C92A2A, already in code and missing from DESIGN.md. Used for every error label. |
| New color tokens | None. |
| Reused | card, Invites row card style, the 28pt overlapping avatar stack from the lock sheet, the `badge` outline style from HOSTING, the teal link row from "Unlock with availability", the create sheet's field style, `ToastCenter`, and the sheet pattern with Cancel or Done in `accent-hover`. |

## Changes the other issues now need

This review did not edit or comment on any issue. These are the changes for the owner to apply.

| Issue | Change |
|---|---|
| #11 SQL | None. |
| #12 Swift core | `PlaceBoard` also exposes tie information (is the leader tied, with which places) for the TIED badge, the View all subtext and the lock sheet. A lock-projection value of winner, tied or none. A `canSuggest` reason (personal cap, plan full, no city, locked, not a member) so the screen picks the right muted line. A new `UserFacingError.Action` for bring back, because the cap errors read differently there. Four more fixtures: `placesZeroVotes`, `placesOwnLeader`, `placesDeparted`, `placesCapped`, bringing the total to thirteen. |
| #13 Design round | Satisfied by this document, once the owner approves it. |
| #14 UI | **Drops** `InviteCard.lockedPlace`: the winner is a row under the card (1.4A). **Replaces** "scrolls to that row" with the inline duplicate panel (2.6B). **Adds:** the lock sheet place row and closing line (1.3A), 44pt duration segments, the shared error fix (5.1A), the toast host on the Invite screen (2.2A), the outlined pill and DESIGN.md entry (5.2A), the departed-friend avatar (5.3A), the places list sheet with passed rows and Bring back (2.3A), the vote history sheet and no-winner line (1.4A), the city row with a last-used city (3.1A), the cap line (7.5A), the reconcile behavior (2.8A), and `ContrastTests` rows. The lock sheet and `FriendAvatar` join its file list. |

## Journey

```
STEP | USER DOES                     | USER FEELS                     | PLAN SPECIFIES
-----|-------------------------------|--------------------------------|----------------------------
1    | Host creates a plan           | hopeful, not blocked           | city row, reason, prefill (3.1A)
2    | Host shares the invite        | expectant                      | unchanged
3    | Friend joins, marks times     | committed                      | existing
4    | Friend scrolls to Where?      | "I can weigh in"               | PL-1, 1.5A
5    | Friend sees no places yet     | invited to contribute          | 2.1A
6    | Friend suggests a place       | proud, slightly exposed        | 2.2A toast
7    | Others vote, friend sees who  | social, curious                | 1.2A names
8    | Host passes on a suggestion   | stung, but told the cost       | 2.3A
9    | Host locks the date           | decisive, final                | 1.3A, 3.2A
10   | Friend sees the winner        | satisfied, ready to go         | 1.4A, Open in Maps
11   | Locked with no winner         | informed, not confused         | 1.4A line
```

## NOT in scope

- The winner on the Invites list rows and My commitments rows. Deferred to `TODOS.md` (TODO 1), because R8 stops at the card and the share text.
- A notice to a voter whose vote was cleared (2.4B). The server keeps no history, so none can be sent to a voter who was not watching.
- Optimistic voting. Mutations stay server-first.
- A map view, ratings, photos, hours, comments, push notifications and favorites across plans. Already out of scope in #10.
- Realtime and cross-phone behavior. That belongs to the Supabase store follow-up in #10.
- A configurable search radius. The radius stays 25 km.
- A reorder animation. The list order is frozen while open.
- iPad layout and landscape. The sheets follow system behavior and nothing here is designed for them.
- Dark mode. The app is light only.

## What already exists

- DESIGN.md: tokens, the card, the pill components, the toast, the inline error, the badge style, motion rules and the contrast table.
- `ContrastTests` with the WCAG formula, and the rule that new components add their own pairs.
- The Invites list row, the lock sheet's avatar stack with `+N`, `FriendAvatar` and `StatusDot`.
- The create sheet's field style, the pushed navigation pattern and the sheet pattern with detents.
- `ToastCenter` with its VoiceOver announcement, on Home today.
- The existing lock placeholder: a success haptic and 320ms crossfades. The full lock morph is already a TODO and the winner row should join it when it ships.

## Implementation Tasks

Synthesized from this review's findings. Each task derives from a specific decision. Effort is human / CC. Checkbox as you ship.

- [ ] **T1 (P1, human: ~1.5d / CC: ~45min)** Places section: leader card variants. Surfaced by 1.1A, 1.2A, 2.1A, 2.7A, 6.1A, 7.5A. Files: `app/FriendCal/Views/Places/PlacesSection.swift`, `app/FriendCal/Views/LockedInvite/LockedInviteView.swift`. Verify: UI tests per fixture, iPhone SE and accessibility size 3.
- [ ] **T2 (P1, human: ~1d / CC: ~35min)** Places list sheet: frozen sort, passed section, ellipsis menu, Bring back, plus button pushing search. Surfaced by 2.3A, 2.5A, 7.2A. Files: `PlacesListSheet.swift`. Verify: UI tests for veto, withdraw, bring back.
- [ ] **T3 (P1, human: ~1d / CC: ~35min)** Search screen: prompt and hint states, spinner row, inline duplicate panel, two presentations. Surfaced by 2.6B, 7.1A, 7.2A, 1.5A. Files: `PlaceSearchSheet.swift`. Verify: UI tests with the fixture search and each failure argument.
- [ ] **T4 (P1, human: ~1d / CC: ~30min)** City row and picker in New plan and Edit plan, with last-used city, caption and Edit caption. Surfaced by 3.1A, 2.7A, 7.3A. Files: `CreateProposalSheet.swift`, `CityPickerView.swift`. Verify: Create needs a city; Edit enabled with frozen dates.
- [ ] **T5 (P1, human: ~4h / CC: ~20min)** Lock sheet: place row, closing line, 44pt segments. Surfaced by 1.3A and TODO 2. Files: `LockSheet.swift`, `LockedInviteUITests.swift`. Verify: new SE assertion for the segments.
- [ ] **T6 (P1, human: ~1d / CC: ~30min)** Winner row, how-the-vote-went sheet, no-winner line, Open in Maps, lock fade. Surfaced by 1.4A, 3.2A. Files: `WinnerRow.swift`, `VoteHistorySheet.swift`, `LockedInviteView.swift`. Verify: locked fixtures, lock transition test.
- [ ] **T7 (P1, human: ~3h / CC: ~15min)** Shared error fix: `error-text` for inline errors and field errors, 44pt Retry and Details. Surfaced by 5.1A. Files: `LockedInviteView.swift` (InlineError), `CreateProposalSheet.swift` (fieldError). Verify: existing UI tests; no `error` token used for text.
- [ ] **T8 (P1, human: ~2h / CC: ~10min)** Outlined pill component and DESIGN.md entry. Surfaced by 5.2A. Files: `app/FriendCal/Shared/OutlinePill.swift`, `DESIGN.md`. Verify: 44pt test, contrast rows.
- [ ] **T9 (P2, human: ~1h / CC: ~10min)** Departed-friend avatar. Surfaced by 5.3A. Files: `FriendAvatar.swift`.
- [ ] **T10 (P1, human: ~2h / CC: ~10min)** Toast host on the Invite screen for suggest, move and remove. Surfaced by 2.2A, 6.2A. Files: `LockedInviteView.swift`.
- [ ] **T11 (P1, human: ~3h / CC: ~20min)** Stale-error reconcile and per-action copy. Surfaced by 2.8A. Files: `ProposalSession.swift`, `UserFacingError.swift`.
- [ ] **T12 (P1, human: ~3h / CC: ~20min)** VoiceOver stops, identifiers, Reduce Motion, small-phone and large-text layouts. Surfaced by 6.1A, 6.2A. Files: the Places views, `PlacesUITests.swift`.
- [ ] **T13 (P2, human: ~1h / CC: ~10min)** Two `ContrastTests` rows: `textMuted` and `accentHover` on `surface2`. Surfaced by 5.2A and the contrast table. Files: `ContrastTests.swift`.
- [ ] **T14 (P2, human: ~2h / CC: ~15min)** Four fixtures: zero votes, own leader, departed, capped. Surfaced by 2.1A, 5.3A, 7.5A. Files: `FixtureData.swift`.
- [x] **T15 (P3, human: ~15min / CC: ~5min)** Record TODO 1 in `TODOS.md`. Surfaced by the TODO decision. Files: `TODOS.md`. Done in this review.
- [ ] **T16 (P1, human: ~1h / CC: ~10min)** Update issues #12 and #14 to match the table above. Surfaced by the whole review. Files: GitHub issues #12, #14.

Fifteen earlier design-review tasks, DT13 to DT27 from the blocked-day wave, are carried unchanged in the live task list so this list does not drop them. This review did not check which of them release 0.1.1.0 already closed.

## Design Review Completion Summary

```
  +====================================================================+
  |         DESIGN PLAN REVIEW: COMPLETION SUMMARY                     |
  +====================================================================+
  | System Audit         | DESIGN.md exists, UI scope: yes             |
  | Step 0               | 3/10, all 7 dimensions with mockups         |
  | Pass 1  (Info Arch)  | 4/10 -> 8/10 after fixes                    |
  | Pass 2  (States)     | 3/10 -> 8/10 after fixes                    |
  | Pass 3  (Journey)    | 4/10 -> 9/10 after fixes                    |
  | Pass 4  (AI Slop)    | 9/10 -> 9/10, no issues found               |
  | Pass 5  (Design Sys) | 6/10 -> 9/10 after fixes                    |
  | Pass 6  (Responsive) | 4/10 -> 9/10 after fixes                    |
  | Pass 7  (Decisions)  | 5 resolved, 0 deferred                      |
  +--------------------------------------------------------------------+
  | NOT in scope         | written (9 items)                           |
  | What already exists  | written                                     |
  | TODOS.md updates     | 1 item added, 1 folded into #14             |
  | Approved Mockups     | 11 generated (3 superseded), 6 approved     |
  | Decisions made       | 26 added to plan                            |
  | Decisions deferred   | 0                                           |
  | Overall design score | 3/10 -> 8/10                                |
  +====================================================================+
```

Pass 1 and Pass 2 stay at 8 because of two accepted gaps: two outlined pills compete (1.6B) and a cleared vote goes unexplained to someone not watching (2.4B). Both were the owner's choice.

Plan is design-complete once the owner approves on #13. Run `/design-review` after implementation for visual QA.

### Needs the owner's sign-off on #13

1. Every row marked **Proposed** in the Copy section, especially the hint copy and the search error copy.
2. The one **Proposed** state: the View all row is hidden when there is exactly one place.
3. The reading of R8 in "How R8 is read".
4. That `InviteCard` stays unchanged, so #14 drops `lockedPlace`.
5. The proposed identifiers and the four extra fixtures.

## Unresolved Decisions

None from this review.

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 2 | issues_open | mode: HOLD_SCOPE, 1 critical gap (blocked-day wave, not this plan) |
| Outside Review | Codex via plan reviews and design voices | Independent 2nd opinion | 12 | completed | latest design voices: 7 findings, 5 High (this design round) |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 6 | issues_open | 25 issues, 2 critical gaps (blocked-day wave, not this plan) |
| Design Review | `/plan-design-review` | UI/UX gaps | 4 | clean | score: 3/10 -> 8/10, 26 decisions |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | none | none |

**OUTSIDE COVERAGE:** Codex design critique, phase design, completed on 2026-11-08: 7 findings, 5 High, no hard rejection. An independent Claude reviewer also completed with 15 findings.

**CROSS-MODEL:** Six of Codex's seven findings were also raised independently by the Claude reviewer: the lock sheet, voter names and attribution, overflow, city visibility, edge states, and hidden alternatives. Model identity for the Claude reviewer is not recorded. Codex used `gpt-6-astra`.

**VERDICT:** DESIGN CLEARED for the place voting plan (#13), pending the owner's sign-off. No eng review has run on place voting: the recorded Eng and CEO reviews cover the blocked-day wave. Eng review required for #11 and #12.

**UNRESOLVED DECISIONS:**
- + 2 unresolved from prior reviews
