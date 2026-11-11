# Add a friend: build spec

Approved 2026-11-10 at the /autoplan final gate (reply `rec`). This is the one document to build from. It folds the original design plan, the accepted review items (A, R, DS, EN) and the gate answers into a single text; where they disagreed, the later decision is what appears here. The reasoning, findings and audit trail are in `docs/designs/friendcal-add-friend.md`. Item ids in brackets point back to it.

Approved mockups (layout reference):
- Sheet: `~/.gstack/projects/rakinne-friendcal/designs/add-friend-v2-20261110/sheet/variant-A.png`. Two lines differ from the mockup: the expiry text is gone (no expiry) and the wording below replaces "invite".
- Accept: `~/.gstack/projects/rakinne-friendcal/designs/add-friend-v2-20261110/accept2/variant-A.png`.

## 1. What this is

**Add a friend** lets two people connect in FriendCal with one tap each. Each person has one reusable personal link, shown as text and as a QR code. Whoever opens it sees an Accept screen and taps Connect; the two are then friends. There is no approval step by the link's owner and there are no pending rows.

"Invite" keeps meaning plans. The Invites tab is unchanged. [1A, d5]

## 2. What connecting grants

- Each person can read the other's name and avatar.
- Each can poke the other without sharing a plan.
- Every signed-in person can already read anyone's Busy times as plain blocks with no detail; friendship puts a readable name beside them. [R30]
- Nothing else. No plan, place, vote or Busy-block detail becomes readable. `hidden_from` and stealth are untouched and outrank friendship. No policy on `proposals`, `busy_blocks`, `proposal_places`, `place_votes` or `tag_alongs` changes. Tag along works exactly as today: only for plans the person was already sent. [R4]
- Status is not shared by this work. Statuses still live on one device; sharing them is a deferred item. [R6]

## 3. Entry points

- Groups header: `person.badge.plus`, 44pt, `accent-hover`, VoiceOver label "Add a friend", id `groups.addFriend`. [DS13]
- Home wheel empty state: "Add your first fave" with an "Add a friend" pill (was "Invite").
- Crew seat cards are not an entry point and stay as they are. [uc6]
- The Moments "Invite" action opens the same sheet, labeled "Add a friend".

All entry points turn on in the last pull request, together with the web slice. Until then the sheet is reachable from the debug sheet only. [R28]

## 4. Screens

### 4.1 Add a friend sheet
`.medium` and `.large` detents, `presentationBackground(surface)`, grabber. Flat layout, no card, no art. At accessibility sizes it opens `.large` and scrolls. Top to bottom:
1. "Add a friend" (display, stops scaling at xxxLarge) and "Done" in `accent-hover`.
2. Subtitle: "Share your link. Anyone who opens it can connect with you." [uc2]
3. Link row: mono, selectable, shows `friendcal.app/f/<token>` with no scheme and no name hint. Two lines on an iPhone SE at default size; wraps to as many lines as needed at larger sizes; never truncated. One labeled 44pt "Copy". VoiceOver reads the row as "Your friend link" with Copy as its action. [DS8]
4. Muted body line: "Anyone with it can connect." and "Reset link" in `accent-hover`. No expiry text. [uc5]
5. Full-width coral "Share link" (native `ShareLink`). The only coral control. [d5]
6. Quiet 44pt row "Show QR code".

States:
| State | What shows |
|---|---|
| Open with a cached link | The cached link at once; a quiet refresh behind it |
| First open, nothing cached | 56pt skeleton row; Share disabled |
| Link fetch fails | Inline `error-text` "Couldn't get your link", 44pt Retry; Share, Copy and QR disabled |
| Copy | Label becomes "Copied" for 1.5 s, light haptic, VoiceOver announces "Link copied" |
| Reset tapped | Confirm: "Reset your link? The old link stops working for anyone who hasn't joined yet. Friends already connected stay connected." |
| Reset in flight | Progress on the control; Copy, Share and QR disabled |
| Reset done | New link shown; toast inside the sheet "New link ready"; VoiceOver announces it |
| Reset fails | The sheet re-reads the link before enabling anything; if that read also fails, controls stay disabled with Retry [EN12] |

The cached link is stored per account and cleared on sign-out and account deletion. [R23] Share text: "Sam wants to connect with you on FriendCal." followed by the link, built by `ShareText.friendLink(name:url:)`. [uc1]

### 4.2 QR
A push inside the same sheet at `.large`, with a back control. A dark code on a white panel with a quiet zone, whatever the tokens say. Screen brightness is raised while it shows and restored on back, on dismiss and when the app leaves the foreground. The selectable link sits beneath it. Share shares the link, not an image. It mirrors the sheet's loading and error states. [DS14]

### 4.3 Accept
A full-screen cover presented by the shell. If a sheet is open when the link arrives, Accept appears when that sheet closes; nothing is dismissed for it. [EN8] Layout per the mockup: wordmark, the two avatars joined by an arc (initials through `FriendAvatar` when there is no photo), then:
- Headline: "Sam wants to connect"
- One line: "You and Sam will see each other's names and when you're busy. Plan details stay private unless you share them."
- Coral "Connect with Sam"; quiet "Not now".
The name on this screen is the one the server returned, never the URL hint. [R5]

States:
| State | What shows |
|---|---|
| Checking the link | Skeleton for the names; VoiceOver "Checking link" |
| Check fails (network) | Inline error and Retry; the link is kept |
| Connect tapped | Button shows progress and "Connecting"; both buttons disabled |
| Connect fails (network) | Inline error under the button and Retry; link kept. A retry answered "already friends" counts as success [EN15] |
| Dead link | "This link doesn't work anymore." and one button, "OK". No name, no reason, no advice to ask for another [DS5] |
| Own link | "This is your link" and "Share it" (opens the sheet) |
| Already friends | "You and Sam are already connected" and "Open Groups" |
| Not now | Clears the pending link and returns; it does not reappear on next launch |

First run with a pending friend link: sign in, then Accept, then Groups. There is no name step on the real store; a person whose Apple ID withheld a name appears as "Friend" until they set one in Me. [EN9] The notification prompt keeps its current trigger. The sign-in gate's pill reads "Sam wants to connect" (from the hint) or "A friend wants to connect", and its button reads "Continue". Plan-invite wording stays for plan links only. [DS21]

### 4.4 After Connect (recipient)
Dismiss to Groups. Sam's row is highlighted for 2 seconds, the Moments line reads "You and Sam are connected", success haptic, VoiceOver announces the same sentence. The FriendCard does not open by itself. Under Reduce Motion the highlight is a color change only. [DS3, uc7]

### 4.5 Arrival (sender)
The sender learns of a new friend the next time the roster refreshes. The friend is held as "new" until Groups is on screen; until then the Groups tab shows the same dot the Pokes tab uses. Then, once: Moments "You and Jess are connected", haptic, row highlight, VoiceOver announcement. Several at once read "Jess and 2 others" and each row highlights. Nothing reaches a sender whose app is closed until the push forwarder exists. [DS4, d5]

### 4.6 Groups roster and Home wheel
- On the real store Groups lists the caller's friends from the server, plus the caller. A friend with no status shows the existing quiet row. Crews stay on the device and simply list fewer people when a member is no longer a friend. [R8, DS19]
- A failed refresh keeps the last roster on screen and retries on next foreground; an error never produces the "no friends" state. A first load that fails shows the inline error with Retry. [R32]
- The wheel draws the current plan's members. With none, it draws the caller's friends (same 10-face cap and overflow), so the empty state goes away after the first friend. [R10]

### 4.7 Remove a friend
"Remove friend" sits at the bottom of `FriendCard` as a text control in `error-text`, apart from Poke and Tag along. Confirm: "Remove Sam? Sam won't be able to reconnect with your link. To reconnect later, open Sam's link." with "Remove" (destructive) and "Cancel". The dialog closes, the card dismisses, the row dims; on success the row leaves with a toast "Removed Sam"; on failure the row returns with the mapped sentence. The other person is told nothing. [DS6]

### 4.8 Web landing (T4)
One static page at `friendcal.app/f/<token>` in the app's look, CSS variables mirroring `DesignTokens`: wordmark, "Sam wants to connect on FriendCal" (or "A friend wants to connect on FriendCal" without a usable hint), one sentence on finding time with friends, coral "Get FriendCal" pointing at the public TestFlight link, and the line "After installing, tap Sam's link again." There is no short code. [uc4] Variants: in-app browsers get a visible "Open in FriendCal" button; non-iPhone visitors see "FriendCal is on iPhone for now" and no install button. The page is `noindex`, sends `Referrer-Policy: no-referrer`, and loads no third-party script, font or analytics. The name hint is written with `textContent` after the same cleaning as `DeepLink`, capped at 40 characters; never `innerHTML`, never into an attribute. Known limit: the page cannot tell a dead link from a live one. [A8, DS9, EN16]

The same site serves `friendcal.app/p/<id>` for plan links with an equivalent page ("You were invited to <title>"), and the app's plan share text moves to the https form when T4 ships. This closes the "Universal links + not-installed fallback" TODO. [d3]

## 5. Links

- Friend link, two forms parsed into one case: `https://friendcal.app/f/<token>?n=<hint>` and `friendcal://friend/<token>?n=<hint>`. The app shares the custom-scheme form until T4 ships, then the https form (one constant). [A9]
- Token: exactly 22 characters of `[A-Za-z0-9_-]`. Anything else is not a link and shows the existing toast "That link isn't a FriendCal invite". [DS8]
- The https form is accepted only for host `friendcal.app` exactly and path `/f/<token>` or `/p/<uuid>` exactly. [EN16]
- Name hint `n`: cleaned by `DeepLink.sanitizedTitle`, which takes the cap as a parameter: 40 for the hint, 80 for plan titles as today. The hint is shown only on the sign-in pill and the landing page. [R5, R15]
- `DeepLink` gains a `.friend(token, name)` case; `proposalID` and `title` stop being total and their call sites are updated.

### Link router [EN1]
One owner above sign-in (`LinkRouter`, attached at `RootGateView`) receives every opened URL, parses it once and stores the pending link on the device. It replaces the replay code at `FriendCalApp.swift:118`, which never worked because nothing stored the link.
- A plan link opened while signed out survives sign-in and lands on that invite; a failed join keeps the link for a retry.
- A friend link opens Accept and calls nothing but preview until Connect is tapped.
- One pending link at a time; the most recently opened wins. Each carries a generation number so finishing an older one never clears a newer one.
- Cleared when answered, on "Not now", on sign-out and on account deletion. It survives a cancelled sign-in and a relaunch.

## 6. Server

### 6.1 Objects and where they live [EN4]
`supabase/schema_additions.sql` (runs first):
- `friendships`: one row per pair, smaller id first, a check enforcing the order, the pair as primary key, an index on the second column, `created_at`.
- `friend_links`: one row per user (`user_id` primary key), `token` unique, `created_at`, `token_accepts` (reset on each new token), lifetime `accept_count`, `mint_count`, `last_accepted_at`. No expiry column. [uc5, EN17]
- `friend_removals(remover, removed, created_at)`, primary key on the pair.
- All three: row level security on, every client privilege revoked, no client policy.
- `friendcal_is_friend(p_other uuid)`: definer, `stable`, takes only the other person's id and reads `auth.uid()` itself, executable by `authenticated`.

`supabase/rls.sql`: the three tables join the RLS-on guard list.

`supabase/users_auth.sql`:
- One added arm on `users_read_self_and_co_participants`: the row's owner is a friend of the caller. Column grants are untouched.
- `delete_account()`: the caller always joins the user-lock set, and the caller's friendships, link and removal records in both directions are deleted in the same transaction.

`supabase/social.sql`:
- `send_poke`: the gate becomes "active, and friends or share a plan neither is hidden from", evaluated after the user locks are taken. The refusal stays `FC_NOT_FRIEND`. [A3, EN2]
- `push_outbox` kind list gains `friend_joined`, changed in place with a drop-and-add that is safe to re-run.

`supabase/friends.sql` (new, applied after `social.sql`; added after it in `scripts/test-sql.sh:63` and the README order): the six client functions below and a self-check.

### 6.2 Functions
All are definer functions with `search_path = public`, take no user parameter, revoke execute from `public` and `anon`, and grant it to `authenticated`. All refuse a caller with no active `users` row. Guards on nullable booleans use `is not true`. [EN6, EN19]

| Function | Behavior |
|---|---|
| `friend_link()` | Returns the caller's link; mints one only when the caller has none |
| `reset_friend_link()` | Replaces the token, zeroes `token_accepts`, bumps `mint_count`. Never removes a friendship |
| `preview_friend_link(token)` | Returns one of: `valid` with the inviter's id, name and avatar; `own`; `already`; `dead` |
| `accept_friend_link(token)` | Same four answers. On `valid` it inserts the friendship, bumps the counters and writes one push row |
| `remove_friend(p_user)` | Deletes the pair. Writes a removal record only if a friendship was actually deleted. Idempotent |
| `my_friends()` | The caller's friends with id, name, avatar and time connected; never a deleted account |

Rules:
- **Token:** 22 base64url characters from one `gen_random_uuid()` value (122 random bits, no extension needed). Never returned to anyone but its owner. [EN3]
- **Dead link:** an unknown token, a reset token, a deleted inviter, a caller the inviter removed, and a token that has reached 50 accepts all give the same `dead` answer from both preview and accept. [EN5, EN18]
- **Idempotent accept:** a double tap, a retry after a lost reply, and two people accepting each other's links all end with one friendship row.
- **Removal:** the removed person gets `dead` on the remover's links, before and after a reset. The record is cleared when the remover accepts the removed person's link, and by either account's deletion. Because a record is written only when a friendship was deleted, two people can never hold records against each other. Pokes already sent stay in the inbox and show "A friend" when the name is no longer readable.
- **Push:** when accept inserts a new friendship it writes one `push_outbox` row to the inviter: kind `friend_joined`, title "<name> connected with you", body "You two are connected.", data `{"kind":"friend_joined","user_id":"<joiner id>"}`, expiring 24 hours later. No row on a repeat accept or for a deleted inviter. The app-side routing for this kind is not built here; it belongs to the push forwarder work. [R19, R22]
- **Locks:** accept, remove and reset take `friendcal_lock_users` on the people involved, then re-read what they depend on. Accept checks accounts with `is_active()` and takes no `users` row lock. `send_poke` re-checks after its lock. Result against a concurrent change, in either commit order: an accept that commits before a reset stays connected; one that arrives after answers `dead`; a friendship never survives beside a deleted account; a poke never follows a removal. [R24, R26]

## 7. App

### Store seam [A2, R14]
`ProposalStore` gains `friendLink()`, `resetFriendLink()`, `previewFriendLink(token:)`, `acceptFriendLink(token:)`, `friends()`, `removeFriend(_:)`. `SupabaseProposalStore` calls the functions above. `InMemoryProposalStore` mirrors them (its `friendIDs` set becomes the friendships table, with links and removals beside it) and uses the injected clock. `UserFacingError` maps each new refusal to one sentence; `FC_NOT_FRIEND` now reads "You can only poke friends."

### Roster rules [EN11, EN13, R25]
A `FriendCalCore` type, `FriendRoster`, owns the rules so the fast test lane covers them; `GroupsSession` holds state and gains a store reference and an async `refresh()` called on appear, on foreground and after a local accept or remove.
- Each refresh takes a generation number; a local accept or remove bumps it; a refresh started under an older number is discarded.
- A per-account saved set of friend ids decides what is "new". It is first filled by the first roster load after sign-in, and "never loaded" differs from "loaded and empty", so a new user's first friend is announced. When the recipient taps Connect the inviter's id joins the set before the call. An id that leaves the roster leaves the set.
- `FriendRoster` also answers the wheel's face source.

### Test hooks, documented in CLAUDE.md
- `-FriendCalFriendLink valid|dead|own|already`: what the in-memory store answers for the opened token.
- `-FriendCalPendingLink none|<url>`: pins the stored pending link.
- `-FriendCalFailNext` gains `friendLink`, `resetFriendLink`, `acceptFriendLink`, `removeFriend`.

## 8. Tests

The full list with value cards is in the test plan at `~/.gstack/projects/rakinne-friendcal/rakinnefoote-fix-rls-allow-all-and-recipient-case-eng-review-test-plan-20261110-154301.md` (written before the gate: ignore its expiry cases). Required, by lane:

**SQL (`scripts/test-sql.sh`, through the `t.*` helpers, `t.uh(n)` ids where case matters)**
- Each function's answers: mint, reset, valid, own, already, and every dead cause, with preview and accept agreeing.
- Token: 22 characters, right alphabet, no repeats over 1,000 mints.
- One friendship per pair under double accept and mutual accept; one push row, none on repeat, 24-hour expiry.
- Cap: the 50th accept works, the 51st is dead, a reset starts over.
- Remove: both sides lose name and poke through friendship; removing a non-friend writes nothing; the removed person is dead on the remover's links; the remover can reconnect; a poke through a shared plan still works.
- Policy: a friend reads the other's name; a stranger does not; a friend who is not a recipient reads none of the other's plans; `hidden_from` still answers "no such plan"; a friend reads a Busy block's time and none of its hidden columns.
- Access: a client read of each of the three tables is refused with 42501; RLS is on; `anon` is refused on every new function; the self-check fails if any of that changes.
- Deletion: a deleted account is nobody's friend, has no link and no removal records either way.
- Ordering: accept against reset, deletion and removal, and poke against removal, in both commit orders.
- Upgrade: the social schema from `origin/main` with one queued poke push takes this wave, keeps the row, then accepts a `friend_joined` row; applying the wave twice stays green.

**Core (`swift test`)**
- `DeepLink`: both friend forms, plan https form, wrong host, extra path parts, tokens of 21 and 23 characters, the 40-character hint cap.
- `FriendRoster`: first load silent, one new friend, several, removed id, stale generation discarded, wheel source in both cases.
- In-memory store: each answer and refusal; a reset that applies and then throws; a throwing `friends()` leaves the roster unchanged; a second account sees neither the first account's cached link, pending link nor saved set.
- `UserFacingError`: one sentence per new refusal. `ShareText.friendLink`.

**App and UI (`xcodebuild test`)**
- Sheet: each state; on iPhone SE (3rd generation) and at AX3 the whole link is present and unclipped.
- Accept: each state through the launch arguments; double tap; Not now does not return on relaunch.
- Router: signed-out plan link lands on the invite after sign-in (regression contract); signed-out friend link reaches Accept; a failed join keeps the link; a newer link replaces an older one; a friend link opened with the New plan sheet up shows Accept when the sheet closes.
- After connect: row highlight and Moments line, no card; the wheel's empty state goes away; the sender's tab dot and held arrival.
- Remove: confirm text, row leaves; failure returns the row.

**Manual, on a device (T4)**
- Tap the https link with the app installed and not installed; from an in-app browser; on a non-iPhone.
- Name hint containing `<img onerror=...>` and a bidi override renders as plain text.

## 9. Delivery

Three pull requests, in this order. [EN20]

| PR | Tasks | Contents | Effort (human / Claude Code) |
|---|---|---|---|
| 1 | T1 | Everything in section 6 and its SQL tests | ~3d / ~2.5h |
| 2 | T2, T3, T5 | Store seam, `DeepLink`, router, Accept, sheet, QR, roster, arrival, Remove, wheel; sheet reachable from the debug sheet only | ~5d / ~5h |
| 3 | T4, T6, T7 | Static site, AASA, associated domains, https links for friends and plans, entry points on, DESIGN.md components | ~1.5d / ~2h |

PR 1 and PR 2 can be built in parallel: PR 2 works against the in-memory store and wires the real store when PR 1 merges.

T4 prerequisites, started alongside T1: the `friendcal.app` domain serving HTTPS from a static host; `apple-app-site-association` with app ID `6589A6M74D.com.friendcal.app` and paths `/f/*` and `/p/*`; `com.apple.developer.associated-domains` in `app/project.yml` followed by `xcodegen generate`; a public TestFlight link, which needs Beta App Review. [A10, q1]

Apply order for the SQL: `schema_additions.sql`, `lock_proposal.sql`, `rls.sql`, `users_auth.sql`, `join_proposal.sql`, `commitments.sql`, `places.sql`, `social.sql`, `friends.sql`. SQL ships before the app build that calls it. After applying to the live project, diff `pg_policies` against the repo; the live project has drifted before.

Post-deploy check: mint a link on one account, accept on another, see both rosters, remove, see the dead-link line.

Counting [R29]: the README gains one saved query reporting links minted, accepts, friends per person, and new friendships followed by a shared plan within 7 days. Proposed measure: within 14 days of PR 3, half of testers have at least one friend.

DESIGN.md additions (T7): link row, accept screen, tab dot, Remove control, and a decisions-log row.

## 10. Not in this work

Each has a TODOS.md entry unless marked.
- Push forwarder and the app-side handling of `friend_joined`. Planned next, on its own.
- Statuses on the server, readable by friends.
- Connecting through a plan: joining a host's plan offers the connection. To be designed next. [uc3]
- A name step before the first Connect when the name is still the placeholder.
- A join count on the sheet.
- A general block list (Remove already stops one person reconnecting).
- Sender approval of each request, Contacts, pending rows, friends seeing each other's heatmap, an editable share message, a "You're connected" full screen: rejected or out of scope, no TODO.
