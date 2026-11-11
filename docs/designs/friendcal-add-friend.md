<!-- /autoplan restore point: "/Users/rakinnefoote/Developer/friendcal/.gstack/tmp/autoplan/fix-rls-allow-all-and-recipient-case-autoplan-restore-20261110-150122.md" -->
## Implementation plan
# Add a friend (design plan)

Reviewed 2026-11-10 with /plan-design-review. 16 decisions, ids below match the review. Approved mockup:
`~/.gstack/projects/rakinne-friendcal/designs/invite-friend-sheet-20261110/variant-A.png` (structure only; the art strip, card shell, duplicate Copy and Contacts row are superseded by 4A and 4B).

## Naming (1A)
The feature is **Add a friend**. The bottom tab **Invites** (`envelope`) keeps meaning plans only. Entry points all open the same sheet:
- Groups header "+" (new, `groups.addFriend`)
- Home wheel empty state: "Add your first fave" + "Add a friend" pill (was "Invite")
- Groups "Open seat" cards, relabeled "Add a friend" (a joiner lands in "Friends on FriendCal", never in the originating folder)

## Link model (1B)
One reusable personal link per user, 7-day expiry, redeemable by anyone who has it. There are no per-person pending rows: Groups never claims a delivery it cannot verify. A friend simply appears when they connect.

## Screens
1. **Add a friend sheet** (`.medium` + `.large`, `presentationBackground(surface)`, grabber). Flat utility layout, no art strip, no card shell (4A):
   - "Add a friend" (display, stops scaling at xxxLarge) + teal "Done"
   - Subtitle: "Share your link. Friends who open it can ask to connect." (5A)
   - Link row: mono link, selectable, wraps to 2 lines, one labeled 44pt "Copy" control (no duplicate Copy pill)
   - Body-size muted line: "Expires Nov 17 · Anyone with it can ask to connect." + teal "Reset link" (5A)
   - Full-width coral "Share invite" (native `ShareLink`, the only coral control)
   - Quiet 44pt "Show QR code" row (4B). No Contacts row in v1.
2. **QR sheet** (`.large`): large code, the selectable link, Share first in focus order.
3. **Accept screen** (recipient, after sign-in; never auto-accepts, 3A): FriendCal wordmark, headline "Sam invited you to connect", one line "Sam will see your name and status. Your plans stay private unless you share them." (7A), coral "Connect with Sam", quiet "Not now". Auth preserves the pending invite and returns here.
4. **Web landing** (universal link, not installed, 3B): one screen in the app's look: wordmark, "Sam invited you to FriendCal", one sentence on finding time with friends, one coral "Get FriendCal", and a short code to recover the invite on first launch. CSS variables mirror DesignTokens. Requires an apple-app-site-association file, a domain and a static page.
5. **After Connect** (3C): dismiss to Groups, Sam's row highlighted 2s, Moments line "You and Sam are connected", success haptic, Sam's FriendCard opens with the existing Poke and Start a plan actions. If the card feels busy on first launch, fall back to the highlighted row alone. No new coral control.

## Share message (7C)
"Sam wants to connect with you on FriendCal — see when you're both free." + link, built by a new `ShareText.friendLink(name:url:)` beside the plan version, with the same title-hint sanitizing as `DeepLink`. The link preview uses the landing's title and a share image (wordmark + sun, no text in art).

## Interaction states
| Surface | Loading | Empty | Error | Success | Partial |
|---|---|---|---|---|---|
| Sheet link | Show cached link instantly, refresh quietly. First open with none: 56pt skeleton row, Share disabled | n/a | Inline error-text "Couldn't get your link", 44pt Retry + Details; Share disabled | Copy label swaps to "Copied" 1.5s + light haptic | Expired: row dims, "Link expired", Share becomes "Make a new link" |
| Reset link | n/a | n/a | Inline error-text + Retry | Confirm dialog "Reset your link? The old link stops working for anyone who hasn't joined yet. Friends already connected stay connected." then toast "New link ready" | Old link shows recipients "expired" |
| Recipient landing | Redeeming skeleton | n/a | No network: inline error-text + Retry, the invite is kept | "Connected" lands in Groups (screen 5) | Expired/reset: "Sam's link has expired", "Ask Sam for a new one". Already friends: "You and Sam are already connected", "Open Groups". Own link: "This is your link", "Share it". Never reveal why beyond "expired" |
| Sender arrival | n/a | Wheel empty state until the first friend | n/a | In app: Moments "Jess joined", row in "Friends on FriendCal", success haptic, wheel shows her face. Away: push "Jess joined FriendCal" opens Groups (new `friend_joined` kind in push_outbox) | Reduce Motion: color-only highlight, no animation |

## Visibility contract (7A)
Connecting lets each person see the other's name, avatar and Groups status/presence, and lets them Poke and Tag along to plans the host shares with them. It never exposes plans or Busy blocks. Stealth and `hidden_from` outrank friendship (the same rule as `join_proposal`, D12). Needs a friendships table and a `users` read-policy change, tested through the `t.*` helpers (use `t.uh(n)` for case tests).

## Accessibility and responsive (6A, 6B)
- Detents `[.medium, .large]`; at Accessibility sizes the sheet opens `.large` and scrolls. The link wraps and stays selectable, never ellipsized. Every control is 44pt and wraps its label. UI test on iPhone SE (3rd generation) and at AX3.
- Every new control gets a label and trait. State changes (copy, arrival) use VoiceOver defaults; custom announcements are **not** specified (user-deferred, see TODO).
- Tokens only: `DesignTokens` colors and the D27 type table. New DESIGN.md components: link row, accept screen.

## What already exists (reuse)
`ShareLink`, `ShareText`, `DeepLink` + title sanitizing, `AuthGateView` invited pill, `InviteSeatCard`, `FriendCard`, Moments line, `SocialSession`, `push_outbox`, the `.sheet` + detents + `presentationBackground` pattern from Groups and Tag Along, `PressableStyle`, `.sensoryFeedback`.

## NOT in scope
- Pick from Contacts (permission prompt, denied state and send mechanism undefined; the system share sheet covers it)
- Per-person pending/ghost rows, Resend/Cancel per person (the reusable link cannot know recipients)
- Friends seeing each other's heatmap (collides with X1 and the open busy-block TODO)
- A "You're connected" full screen and a second authored motion moment (the lock morph stays the only one)
- Editable share message
- Custom VoiceOver announcements (deferred by the user)

## Implementation tasks
- [ ] **T1 (P1, human ~1d / CC ~1h)** friendships table, `friend_links` (one reusable link per user, expiry, reset), redeem/accept RPC, `friend_joined` push kind, users RLS for name + status only, `t.*`-helper tests. Surfaced by: 1B, 7A, 2C. Files: `supabase/*.sql`, `supabase/tests/`. Verify: `scripts/test-sql.sh`.
- [ ] **T2 (P1, ~4h / ~30min)** Add-a-friend sheet + QR sheet: flat layout, link cache + refresh, Copy "Copied", Reset confirm, expired state, Dynamic Type scroll. Surfaced by: 2A, 4A, 4B, 5A, 6A, 7B. Files: `app/FriendCal/Views/Groups/`, `Views/Home/FriendsWheel.swift`. Verify: iOS lane + SE and AX3 UI tests.
- [ ] **T3 (P1, ~3h / ~20min)** Accept screen + recipient failure states + auth round-trip that preserves the pending invite. Surfaced by: 2B, 3A. Files: `Views/Auth/`, `Models/DeepLink.swift`. Verify: UI tests per state.
- [ ] **T4 (P1, ~1d / ~1.5h)** Universal link + AASA + web landing + first-launch code recovery. Surfaced by: 3B (D16). Verify: tap link with and without the app.
- [ ] **T5 (P2, ~2h / ~15min)** Arrival: Moments line, row highlight, FriendCard auto-open, wheel face, `ShareText.friendLink`. Surfaced by: 2C, 3C, 7C.
- [ ] **T6 (P2, ~1h / ~10min)** Rename "Invite" to "Add a friend" on Home wheel, Groups seat cards and add the Groups "+" (update accessibility ids and UI tests). Surfaced by: 1A.
- [ ] **T7 (P3, ~30min / ~5min)** DESIGN.md: link row and accept screen components, decisions-log row.

## Design Review Completion Summary
```
  | Step 0               | 1/10 initial; focus: all 7 passes + mockups |
  | Pass 1  (Info Arch)  | 3 → 8                                        |
  | Pass 2  (States)     | 2 → 8                                        |
  | Pass 3  (Journey)    | 3 → 8                                        |
  | Pass 4  (AI Slop)    | 6 → 9                                        |
  | Pass 5  (Design Sys) | 8 → 9                                        |
  | Pass 6  (Responsive) | 3 → 7  (VoiceOver announcements deferred)    |
  | Pass 7  (Decisions)  | 3 resolved, 0 deferred                       |
  | Approved Mockups     | 3 generated, 1 chosen (structure superseded) |
  | Decisions made       | 16                                           |
  | Overall design score | 2/10 → 7/10                                  |
```
Unresolved: custom VoiceOver announcements ("Link copied", "Jess joined") are not specified.

## Approved Mockups
| Screen | Path | Direction | Notes |
|---|---|---|---|
| Add a friend sheet (original) | ~/.gstack/projects/rakinne-friendcal/designs/invite-friend-sheet-20261110/variant-A.png | Warm utility sheet, coral Share, outlined teal pills | Superseded: art strip, card shell, duplicate Copy and Contacts row were dropped (4A, 4B) |
| Add a friend sheet (post-review) | ~/.gstack/projects/rakinne-friendcal/designs/add-friend-v2-20261110/sheet/variant-A.png | Flat sheet: hairline link row, one Copy, Reset link, coral Share, QR row | Matches 4A, 4B, 5A; APPROVED 2026-11-10 (board rating 5/5) |
| Accept screen (post-review) | ~/.gstack/projects/rakinne-friendcal/designs/add-friend-v2-20261110/accept2/variant-A.png | Wordmark, Sam + You joined by an arc, sun and foliage, full portrait frame | APPROVED 2026-11-10 (board rating 5/5); replaces the cropped `accept/` set |

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 0 | — | — |
| Outside Review | Codex + Claude subagent, `/plan-design-review` | Independent 2nd opinion | 1 | completed | 8 Codex findings + 6 subagent findings, all addressed or deferred |
| Eng Review | `/autoplan` | Architecture & tests (required) | 0 | — | — |
| Design Review | `/plan-design-review` | UI/UX gaps | 1 | issues_open | score: 2/10 → 7/10, 16 decisions |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

**OUTSIDE COVERAGE:** codex, design phase, completed; findings merged into Passes 1–7.
**CROSS-MODEL:** Claude subagent and Codex agreed on the sheet duplication, the link-model contradiction, the missing recipient landing and the Invites naming collision.
**VERDICT:** DESIGN REVIEW COMPLETE with one open gap; eng review required.

**UNRESOLVED DECISIONS:**
- Custom VoiceOver announcements for "Link copied" and "Jess joined" were deferred by the user (6B); Pass 6 stays at 7/10.

<!-- autoplan-accepted:ceo -->
- A1 Groups roster. `ProposalStore` gains `friends()` returning the caller's friends (id, name, avatar). On the Supabase store, Groups lists exactly those people plus the caller; fixture seeding stays for the in-memory store and UI tests. A friend who connects appears in "Friends on FriendCal" after the next refresh (foreground, pull, or push arrival). Test: a core test that `GroupsSession` built from a store with two friendships lists two friends; a UI test that accepting a link in the in-memory store adds the row.
- A2 Store seam. `ProposalStore` gains `friendLink()` (get or mint), `resetFriendLink()`, `previewFriendLink(token:)`, `acceptFriendLink(token:)`, `friends()`, `removeFriend(_:)`. `InMemoryProposalStore` implements them row for row with the SQL (its `friendIDs` set becomes the friendships table). `UserFacingError` maps each new hint to one sentence. New launch arguments make each recipient state reachable in UI tests and are documented in CLAUDE.md. Test: `swift test` covers every refusal; `-FriendCalFailNext` covers link fetch, reset and accept.
- A3 Poke gate. `send_poke` allows the poke when the two people are friends or share a plan neither is hidden from. Every other case keeps the single `FC_NOT_FRIEND` refusal. The sentence shown becomes "You can only poke friends." Test (SQL, through `t.*`): friends with no shared plan can poke; after `remove_friend` they cannot; a stranger still gets `FC_NOT_FRIEND`.
- A4 Push kind. `push_outbox` accepts `friend_joined` on a fresh schema and on one upgraded from `origin/main` with rows present. `PushRoute` parses it; the shell opens Groups. `-FriendCalPushTap friend/<uuid>` stands in for the tap. The row is written to the inviter when someone accepts their link, never to a deleted account. Test: SQL test on both schema lanes; `PushRoute` unit test; UI test for the tap.
- A5 Remove a friend. `remove_friend(p_user)` deletes the pair, is idempotent, tells the other person nothing and writes no push. After it, neither can read the other's name through friendship or poke through friendship; anything a shared plan grants is unchanged. `FriendCard` shows a quiet "Remove friend" with a confirm dialog; no coral. Test: SQL test for both directions and idempotency; UI test for the confirm and the row leaving.
- A6 Deletion. `delete_account()` deletes the caller's friendships and `friend_links` row in the same transaction. Test: SQL test that a deleted account is nobody's friend and its old link answers "expired".
- A7 Link contract. The token is at least 128 bits from a CSPRNG, URL-safe. One `friend_links` row per user. Reset replaces the token and the expiry. Preview and accept take only the token and read `auth.uid()`. An unknown, reset, expired or deleted-inviter token all return the same "expired" answer. Accept is idempotent (double tap, both people accepting each other's link, retry after a dropped response all end with one friendship). A friendship is one row per unordered pair. Own link and already-friends are distinct, non-error answers. The accept screen shows the inviter name the server returned, never the URL hint. Guards on nullable booleans use `is not true` (learning `plpgsql-if-not-null-fails-open`). Test: SQL tests for each answer, using `t.uh(n)` ids for any case-sensitive comparison.
- A8 Landing text safety. The landing page writes the name hint with `textContent`, after the same sanitizing rules as `DeepLink.sanitizedTitle`, capped at 40 characters, and falls back to "A friend". No `innerHTML`, no hint in any attribute or URL. Test: a page test (or manual checklist item) with `<img onerror>` and a bidi override in the hint.
- A9 Two link forms. `DeepLink` parses `friendcal://friend/<token>?n=<hint>` and `https://<domain>/f/<token>?n=<hint>` into the same case. Until the domain is live the app shares the custom-scheme form; T4 flips one constant. T1, T2, T3, T5, T6 do not depend on T4. Test: `DeepLink` unit tests for both forms and for malformed tokens.
- A10 T4 prerequisites, stated in the task: the domain is owned and serves HTTPS; a static host; `apple-app-site-association` with app ID `6589A6M74D.com.friendcal.app`; `com.apple.developer.associated-domains` in `app/project.yml` followed by `xcodegen generate`; a public TestFlight link (needs Beta App Review) as the "Get FriendCal" target. T4 does not start until the first is true.
- E11 Add the TODOS.md entry "Custom VoiceOver announcements for Link copied and friend joined" that the plan already points to.
- Deferred, each with a TODOS.md entry written at approval: push forwarder Edge Function (A11); statuses on the server gated by friendship (E8); link join count on the sheet (E4); block a person (E10).
- R1 (refines A5) Remove and the link. Removing someone does not stop them reconnecting with a link they still hold. The confirm dialog says so and offers three choices: "Remove", "Remove and reset link", "Cancel". The second calls remove then reset. Test: UI test for each choice; SQL test that a removed person can accept again unless the link was reset.
- R2 (refines A7) Access to the new tables. `friendships` and `friend_links` have row level security on, no client grants and no client policy; every read and write goes through a definer function. Both tables are added to the RLS-on guard list in `supabase/rls.sql` and the new SQL file is added to `WAVE_SQL` in `scripts/test-sql.sh` and to the README apply order. A token is never returned to anyone but its owner. Test: `t.*` assertions that an authenticated client reads zero rows from both tables; the self-check fails if RLS is off.
- R3 (refines A4) One push per new friendship. The `friend_joined` row is written only when accept inserts a new friendship row, never on a repeat accept. Title "<joiner name> joined FriendCal", body "You two are connected.", data `{"kind":"friend_joined","user_id":"<joiner id>"}`, no expiry. `-FriendCalPushTap friend/<uuid>` carries the joiner's id; the shell opens Groups and highlights that row. Test: SQL test that a second accept writes no second row.
- R4 (clarifies the Visibility contract) Friendship grants no plan access. "Tag along to plans the host shares with them" describes existing behavior: a friend sees only plans they are already a recipient of. No proposals, busy_blocks, places or tag_alongs policy changes in this plan. Test: SQL test that a friend who is not a recipient reads zero rows of the other's plans and that `hidden_from` still returns "no such plan".
- R5 (refines A7) Where the name hint may show. The Connect screen and its button use the server's inviter name. The URL hint may be shown only where no server name exists: the sign-in pill and the expired state ("Sam's link has expired"). With no usable hint these read "You were invited to connect" and "This link has expired. Ask your friend for a new one."
- R6 (clarifies T1) The `users` change is one added `or` arm on the existing read policy: the two people are friends. Column grants are not touched (`id, display_name, avatar_url, deleted_at`). Status is not a `users` column and is not part of T1; it arrives with the deferred statuses backend (E8).
- R7 (refines A8, A9) One cap for the name hint `n`: 40 characters, in the app parser, the share text and the landing page. A token is 22 to 64 characters of `[A-Za-z0-9_-]`; anything else parses to no link and shows the existing "That link isn't a FriendCal invite" toast. `DeepLink.proposalID` and `DeepLink.title` become optional or move onto the case, and their call sites (`AppTabView.open`, `FriendCalApp` pending-link replay, `AuthGateView` pill) are updated in T3. The landing-page safety check is a manual checklist item in T4 with the two listed inputs.
- R8 (refines A1) `GroupsSession` gains a store reference and an async `refresh()` that replaces `friends` from `store.friends()`; the shell calls it on appear, on foreground and when a push arrives. On the Supabase store, statuses and busy time start empty and crews stay on the device, filtered to current friends (a crew member who is no longer a friend is dropped from display). The row-appears UI test lives in T5 only. Effort re-estimated: human ~1d / CC ~45min.
- R9 (refines A9, A10) Until T4 ships, a friend link only works for someone who already has the app; the share text is unchanged and the Add a friend sheet makes no not-installed promise. The domain is `friendcal.app` (the one `TODOS.md:160` and the mockups name) with path `/f/<token>`; `/p/<id>` joins only if taste decision d3 is approved.
- R10 (resolves the wheel claim) The Home wheel draws the current plan's members. When there are none, it draws the caller's friends instead (same 10-face cap and overflow drawer), so "Add your first fave" disappears once a friend connects. With plan members present the wheel is unchanged. Test: core test for the face source in both cases; UI test that the empty state goes away after an accept.
- R11 (refines R8) Noticing a new friend. `refresh()` compares the returned ids with a per-account set saved on the device. Ids not in the set produce the "Jess joined" Moments line, the success haptic and the row highlight, then join the set. The first load for an account fills the set silently. Test: core test for first load, one new friend, and a removed friend (no announcement).
- R12 (refines A6, A7) Accept under concurrency. Accept takes the shared per-user lock (`friendcal_lock_users`) on both people, then re-reads the token row and both accounts' active state before inserting. `delete_account()` includes the caller in the ids it locks. A link reset or account deletion that commits first makes the accept answer "expired"; one that commits second removes the friendship it finds. Test: SQL test for each order using two sessions or the existing lock-order pattern.
- R13 "Not now" and the pending slot. "Not now" clears the pending friend link and returns to where the person was; the link still works if opened again. The app keeps one pending link: the most recently opened wins, whichever kind it is. Test: UI test that "Not now" does not reappear on next launch.
- R14 (refines A2) `friendLink()` returns the caller's row as it is, including an expired one with its expiry, and mints only when the caller has no row. "Make a new link" and "Reset link" both call `resetFriendLink()`. `friends()` is a definer function (`my_friends()`) returning id, name, avatar and the time connected. Launch arguments: `-FriendCalFriendLink valid|expired|own|already` sets what the in-memory store answers for the opened token; `-FriendCalFailNext` gains `friendLink`, `resetFriendLink`, `acceptFriendLink`, `removeFriend`.
- R15 (refines R7) `DeepLink.sanitizedTitle` takes the length cap as a parameter: 80 for plan titles as today, 40 for the name hint.
- R16 The link preview (landing title and share image) in the Share message section is part of T4 and does not exist before it.
- R17 (refines R2, R6) Where the SQL lives. `friendships`, `friend_links` and the helper `friendcal_is_friend(p_other uuid)` go in `supabase/schema_additions.sql`, which runs first, so the `users` policy in `users_auth.sql`, `send_poke` in `social.sql` and `delete_account()` are each changed in place, in the file that already owns them. The helper is a definer function that takes only the other person's id and reads `auth.uid()` itself, so it cannot answer whether two other people are friends; the policy arm calls it. A new `supabase/friends.sql`, applied last (after `social.sql`), holds the link and friend functions, the `push_outbox` kind swap and the self-check. The Eng phase may move pieces, but not duplicate a function body in two files.
- R18 (replaces R1's two calls) `remove_friend(p_user uuid, p_reset_link boolean default false)` does both in one transaction; "Remove and reset link" passes true.
- R19 (narrows A4, R3) The server side stays: the kind swap and one outbox row per new friendship. The client side (a `PushRoute` case, shell routing, the `-FriendCalPushTap friend/<uuid>` argument) moves to the deferred push forwarder TODO, because nothing can deliver that push yet. An app that later receives the unknown kind simply opens.
- R20 T1 re-estimated with A3, A6, A7, R2, R12, R17: human ~2d / CC ~2h.
- R21 (refines R9) A `friendcal://` link is not reliably tappable in Messages and is not a link at all to someone without the app. Before T4 the feature is for people who have the app and mainly through the QR code; it is not announced as "send a link to anyone" until T4 ships. T4 stays P1.
- R22 (refines R3) The `friend_joined` outbox row expires 24 hours after it is written, so a forwarder that ships later never sends a stale "joined" push.
- R23 The cached link on the sheet is stored per account and cleared on sign-out and on account deletion. Test: core or UI test that a second account never sees the first account's link.
- R24 (corrects R12) Only account deletion removes friendships. A link reset never removes one: an accept that committed before the reset stays connected, matching the Reset dialog's promise. An accept that reaches the server after the reset answers "expired".
- R25 (refines R11) The saved set. It is first filled by the first roster load after sign-in, and "never loaded" is a different state from "loaded and empty", so a new user's first friend is announced. When the recipient accepts, the inviter's id goes into the recipient's set at once, so the recipient sees only "You and Sam are connected", not a second "Sam joined". An id that disappears from the roster leaves the set, so reconnecting after a removal announces again.
- R26 (refines R12, R18) Locks. Accept, `remove_friend` and the link reset all take `friendcal_lock_users` on the people involved. Accept checks account state with `is_active()` and takes no `users` row lock, so it cannot reverse `delete_account()`'s order (row lock, plan locks, then user locks).
- R27 (replaces R1 and R18) Removing someone also stops them reconnecting. `remove_friend(p_user)` deletes the pair and records that the caller removed that person. A later accept of the caller's link by that person gets the same "expired" answer as any dead link. The record is cleared only when the caller accepts that person's link. The dialog is one confirm: "Remove Sam? Sam won't be able to reconnect with your link." No three-choice dialog and no reset flag. Test: SQL test that the removed person's accept answers "expired" before and after a link reset, and that the remover accepting the other's link reconnects them.
- R28 (replaces the release order in R21) Rollout order. The entry points (T6) merge last, together with T4, so nobody is offered "Add a friend" while the link is dead for people without the app. Until then the sheet is reachable from the debug sheet only. The T4 prerequisites in A10 start on day one, in parallel with T1.
- R29 Counting. `friend_links` keeps `accept_count` and `last_accepted_at`; `friendships` keeps `created_at`. The README gains one saved query that reports links minted, accepts, friends per person, and new friendships followed by a shared plan within 7 days. No UI. Proposed measure, for the owner to confirm: within 14 days of T4, half of testers have at least one friend.
- R30 Two factual corrections to the plan text. (1) Screen 5: `FriendCard` has Poke and Tag along; it has no "Start a plan" action (`FriendCard.swift:6`), so the card opens with the two that exist. (2) Visibility contract: every signed-in person can already read anyone's Busy times as plain blocks with no detail (`rls.sql:41`, `:379`); friendship adds a readable name beside them and nothing else. Test: SQL test that a friend reads a Busy block's time and none of its hidden columns.
- R31 Before implementation starts, the accepted items are folded into the plan body as one spec and the sentences they supersede are removed, so nobody builds from the stale half.
- R32 (refines R8) When a roster refresh fails, Groups keeps showing the last roster it loaded and retries quietly on the next foreground; it never swaps to an empty list or the "no friends" state because of an error. A first load that fails shows the existing inline error with Retry. Test: core test that a throwing store leaves `friends` unchanged.
<!-- /autoplan-accepted:ceo -->

<!-- autoplan-accepted:design -->
- DS1 Accept screen container and states. It is a full-screen cover presented by the shell over whatever is on screen; any open sheet stays underneath and is still there on dismiss. States: checking the link (skeleton), ready, Connect in flight (button shows progress and "Connecting", both buttons disabled), failed (inline error under the button with Retry, link kept), and the three non-connect answers shown on the same screen with one action each. Layout follows the approved accept mockup (wordmark, two avatars joined by an arc, headline, one consent line, coral Connect, quiet Not now); a person without a photo gets the existing `FriendAvatar` initials. Test: UI test per state through `-FriendCalFriendLink` and `-FriendCalFailNext`.
- DS2 Mutations in flight. Reset and "Make a new link" show progress on the control and disable Copy, Share and Show QR code until the new link is on screen; on failure the old link stays with an inline error and Retry. Remove closes the dialog, dismisses the card and dims the row; on success the row leaves with a toast "Removed Sam"; on failure the row returns with the mapped sentence. Toasts raised from the sheet show inside the sheet, as the Availability sheet does. Test: UI tests with `-FriendCalStoreLatency` and `-FriendCalFailNext`.
- DS3 After Connect lands on Groups with Sam's row highlighted for 2 seconds, the Moments line and the success haptic. The FriendCard does not open by itself; this is the fallback the plan already names. Under Reduce Motion the highlight is a color change with no animation.
- DS4 The sender's arrival. A new friend is held as "new" until Groups is on screen; until then the Groups tab shows the same dot the Pokes tab uses. Then the Moments line, haptic and highlight play once. Several at once read "Jess and 2 others" and each row highlights. With no push delivery, a sender who is away learns of it on next open; this is a known gap owned by the push forwarder TODO.
- DS5 Dead links. Because a removed person can never use that sender's links again (R27), the dead-link state never tells anyone to ask for a new one. It reads "This link doesn't work anymore." with one button, "OK". The name hint is not shown on this state. (This is also item 4 of wording pack d5; if d5 is declined the neutral line still applies, since the old line is now false for removed people.)
- DS6 Remove. "Remove friend" sits at the bottom of `FriendCard` as a text control in `error-text`, apart from Poke and Tag along. The confirm reads "Remove Sam? Sam won't be able to reconnect with your link. To reconnect later, open Sam's link." with "Remove" (destructive) and "Cancel".
- DS7 If the 7-day expiry stays (UC5), an expired link on the sender's sheet keeps the plan's "Link expired" and "Make a new link" state unchanged.
- DS8 (refines R7) The link. A token is exactly 22 characters of `[A-Za-z0-9_-]`. The row shows `friendcal.app/f/<token>` with no scheme and no `?n=`; Copy, Share and the QR carry the full URL with the name hint. At default sizes that is two lines on an iPhone SE; at accessibility sizes it wraps to as many lines as it needs and is never truncated. VoiceOver reads the row as "Your friend link" with Copy as its action, not the token. Test: UI test on iPhone SE (3rd generation) and at AX3 that the full text is present and nothing is clipped.
- DS9 Landing page states (T4). iPhone Safari: the plan's layout. In-app browsers where the universal link does not fire: a visible "Open in FriendCal" button beside "Get FriendCal". Not an iPhone: "FriendCal is on iPhone for now" and no install button. No usable name hint: "A friend wants to connect on FriendCal". The page is `noindex`. Accepted risk, stated: a static page cannot tell that a link is dead, so someone can install and then meet the dead-link line.
- DS10 First run with a pending friend link: sign in, then the name prompt, then Accept, then Groups. The notification prompt keeps its current trigger (after the first poke) and does not appear in this path.
- DS13 The Groups header control is `person.badge.plus`, labeled "Add a friend" for VoiceOver, 44pt, in `accent-hover`. Every "teal" text or glyph in this plan uses `accent-hover` (D25).
- DS14 QR. Opened from the sheet as a push inside the same sheet at `.large`, with a back control. The code is dark on a white panel with a quiet zone, regardless of tokens; screen brightness is raised while it shows and restored on leaving. The selectable link sits beneath it. Share shares the link, not an image. It mirrors the sheet's loading, error and expired states.
- DS16 Focus returns to the control that opened each sheet when it closes. All new controls are standard buttons and work with Full Keyboard Access and Switch Control without custom handling.
- DS19 A friend with no status on the server shows the existing quiet row. A crew on this device simply lists fewer people when a member is no longer a friend; no empty seat is drawn for them.
- DS20 The pending link survives a cancelled or failed sign-in and app relaunch until it is answered, replaced by a newer link, or dismissed with "Not now".
- DS21 With a pending friend link the sign-in gate's pill reads "Sam wants to connect" (hint) or "A friend wants to connect", and the button reads "Continue". The plan-invite wording ("You were invited to", "Continue to invite") is used only for plan links.
<!-- /autoplan-accepted:design -->

<!-- autoplan-accepted:eng -->
- EN1 Link router. One owner above sign-in (`LinkRouter`, attached at `RootGateView`) receives every opened URL, parses it once, and stores the pending link on the device. It replaces the replay code at `FriendCalApp.swift:118`. A plan link behaves as the app intends today: opened while signed out it survives sign-in and lands on that invite; a failed join keeps the link for a retry. A friend link opens Accept and calls nothing but preview until Connect is tapped. Each pending link carries a generation number so finishing an older one never clears a newer one. The pending link is cleared when it is answered, on "Not now", on sign-out and on account deletion. `-FriendCalPendingLink none|<url>` pins it for UI tests and is documented in CLAUDE.md with the other launch arguments. Test: UI tests for signed-out plan link, signed-out friend link, failed join keeps the link, and newer-replaces-older; unit test for the generation rule.
- EN2 `send_poke` evaluates "active, and friends or share a plan" after it takes the user locks, not before. Test: SQL test that a removal committed while a poke waits on the lock refuses the poke.
- EN3 (replaces the bit count in A7) Token source. A token is 22 base64url characters made from one `gen_random_uuid()` value, which is core Postgres and needs no extension. That carries 122 random bits; the rule becomes "at least 120 random bits". The 22nd character of a 16-byte value is always a letter, so link detection in Messages cannot cut it short. Test: SQL test for length, alphabet and no repeats over 1,000 mints.
- EN4 (replaces R17's file list) SQL layout. `schema_additions.sql` creates `friendships`, `friend_links` and `friend_removals`, each with row level security on and all client privileges revoked in the same statement group, plus `friendcal_is_friend(p_other uuid)`. `friendships` has one row per pair with the smaller id first, a check that enforces the order, the pair as primary key and an index on the second column. `rls.sql` adds the three tables to its RLS-on list. `users_auth.sql` adds one arm to the read policy and changes `delete_account()`: the caller always joins the user-lock set, and the caller's friendships, link and removal records in both directions are deleted. `social.sql` changes `send_poke` (EN2) and replaces the `push_outbox` kind check in place with a drop-and-add that is safe to re-run. `supabase/friends.sql`, applied after `social.sql` and added after it in `scripts/test-sql.sh:63` and the README order, holds the six client functions and a self-check. No function body or list exists in two files.
- EN5 (completes R27) Removal records. `friend_removals(remover, removed, created_at)`, primary key on the pair, same access rules as the other two tables. `remove_friend` writes a record only when it actually deleted a friendship, so nobody can block a stranger and two people can never hold records against each other. Preview and accept both give the removed person the dead-link answer. The record is cleared when the remover accepts the removed person's link, and by either account's deletion. Pokes already sent between the pair stay in the inbox and show the existing "A friend" name when the name is no longer readable. Test: SQL tests for remove-of-a-non-friend writes nothing, preview and accept parity, deletion clears both directions, and remove then poke through a shared plan is still allowed.
- EN6 Function access. Every new function revokes execute from `public` and `anon`. The six client functions and `friendcal_is_friend` grant execute to `authenticated`; everything else grants to nobody. Every definer function sets `search_path = public`. The `friends.sql` self-check fails if `anon` can execute any of them, if a definer function lacks the setting, or if a client role holds any privilege on the three tables. Test: `t.call` shows `anon` refused on each function.
- EN7 (corrects R2's test) A client read of the three tables is refused with SQLSTATE 42501; the test asserts that through `t.call`, and separately that row level security is on.
- EN8 (corrects DS1) Accept and open sheets. The system will not stack a full-screen cover on an open sheet. A friend link opened while a sheet is up is kept by the router and Accept appears as soon as that sheet closes; nothing the person was typing is dismissed. With no sheet up, Accept appears at once. Test: UI test that opens a friend link with the New plan sheet open, closes the sheet, and sees Accept.
- EN9 (corrects DS10) On the real store there is no name step after sign-in; a person whose Apple ID withheld a name is called "Friend" until they set one in Me. The first-run order is sign in, then Accept, then Groups. Deferred with a TODOS.md entry: ask for a name before the first Connect when the name is still the placeholder.
- EN10 Upgrade proof. The SQL upgrade lane loads the social schema as it is on `origin/main` with one queued poke push before applying this wave, and asserts the row survives and a `friend_joined` row can then be inserted. Applying the whole wave twice stays green.
- EN11 Refresh ordering. Each roster refresh takes a generation number; a local accept or remove bumps it; a refresh that started under an older number is discarded when it returns. The saved-set update and the on-screen roster change together. Test: core test with a paused store that returns the old roster after a remove.
- EN12 (corrects DS2) A failed reset proves nothing about whether the link changed. After any reset failure the sheet re-reads `friendLink()` before Copy, Share and QR are enabled again; if that read also fails they stay disabled with Retry. Test: core test where the store applies the reset and then throws.
- EN13 Where the rules live. Roster diffing, the saved set, the refresh generation and the wheel's face source are a `FriendCalCore` type (`FriendRoster`) covered by `swift test`; `GroupsSession` holds state and calls it. Tests the earlier items called "core tests of `GroupsSession`" are tests of this type. Anything that needs the session itself runs app-hosted, as `ProposalSessionTests` does.
- EN14 Expiry is decided by the server. `friend_link()` returns the expiry and an `expired` flag; the app shows the state it is given and only formats the date. The in-memory store uses the injected clock (`-FriendCalNow`).
- EN15 (refines R25) Preview returns the inviter's id as well as the name. The recipient's saved set gains that id when Connect is tapped, before the call, so a reply lost after the server committed cannot produce a second "joined" announcement. A retry that answers "already friends" after the person's own Connect is shown as success.
- EN16 Landing page and link parsing (T4). The page sends `Referrer-Policy: no-referrer` and loads no third-party script, font or analytics, so the token in the path goes nowhere else. `DeepLink` accepts the https form only for host `friendcal.app` exactly and path `/f/<token>` exactly; anything else is not a link. Test: `DeepLink` unit tests for a wrong host, extra path parts and tokens of 21 and 23 characters.
- EN17 (refines R29) `friend_links` also keeps `mint_count`. `accept_count` and `mint_count` are lifetime totals for the person and survive a reset.
- EN18 A token stops working after 50 accepts and answers like any dead link; a reset starts a new count. Test: SQL test at the boundary.
- EN19 Accept, preview and the link functions refuse a caller with no active `users` row with the existing `FC_ACCOUNT_DELETED` refusal. Test: SQL test.
- EN20 Three pull requests, in order: SQL (T1); app with the sheet reachable only from the debug sheet (T2, T3, T5); web, universal links and entry points together (T4, T6). T1 is re-estimated to human ~3d / CC ~2.5h.
<!-- /autoplan-accepted:eng -->
## Review record

/autoplan run `fix-rls-allow-all-and-recipient-case-20261110-150122`, 2026-11-10. The Implementation plan above is kept byte for byte; everything this run accepts is listed in the `autoplan-accepted` blocks below and binds the implementer the same way the plan text does.

### Phase 1: CEO review (SELECTIVE EXPANSION)

#### System audit
- Branch `fix/rls-allow-all-and-recipient-case` (v0.4.1.0, SQL-only RLS fix) is unrelated to this plan; the plan file is the only untracked change. No stash. Nothing for this feature has landed on `origin/main` (`git log origin/main --grep` and `-S friendships` return nothing).
- Hot files this plan touches: `app/FriendCal/FriendCalApp.swift` (12 commits in 30 days), `supabase/rls.sql` (7), `app/project.yml` (16).
- Related TODOS.md items: "Universal links + not-installed fallback" (`TODOS.md:160`, T4 is the same work for a second path), "Poke's build" (`TODOS.md:219`, stale: the table, RPC and inbox shipped in 0.4.0.0, the Edge Function did not), "Groups as a real entity" (`TODOS.md:174`).
- Retrospective: the last two reviews on this repo both found privacy rules that existed in a review file and not in SQL (`docs/DECISIONS.md` "RLS hardening (C1)", learning `live-supabase-had-allow-all-policies`). The visibility contract here is the same shape of risk: a sentence in a design doc that only holds if the policy, the RPC gates and the delete path all say it.
- Taste calibration. Good patterns to copy: `supabase/social.sql` (one header that states the state machine and who may call what, definer RPCs with no user parameter, a self-check block at the end), `app/FriendCal/Models/DeepLink.swift` (outside text sanitized once at the boundary). Pattern to avoid: `app/FriendCal/Views/Groups/GroupsSession.swift:5` (a screen that looks live and is in-memory, with a "Status shared" toast for a status nobody else receives).
- Landscape: search tool not available (Aside not installed, no WebSearch in this session). In-distribution only. Layer 1: every social app that grows by invitation uses one of two models, a per-person request with approval (Facebook, LinkedIn) or a personal reusable link/QR with instant connect (Snapchat, Telegram, Signal usernames, Partiful host links). The reusable link wins on speed and loses on consent, which is why each of those apps pairs it with remove and block. Layer 3: for a tight group of 10 to 20 people the link is right, and the missing half here is the remove path, not an approval queue.

#### 0A. Premise challenge
The real problem: there is no way for a second person to become your friend in FriendCal. `social.sql:22` says so in words ("There is no friends table yet"), and the two entry points that exist are toasts (`HomeView.swift:122`, `GroupsView.swift:184`). Do-nothing cost: Groups, Pokes and the wheel stay demo surfaces for anyone who has not already been sent a plan link. The plan attacks the problem directly, not a proxy.

| # | Premise | Claim in the plan | Receipt | Verdict |
|---|---|---|---|---|
| P1 | A friend "simply appears" in Groups when they connect | Link model, Sender arrival row | `AppTabView.swift:43`, `GroupsFixture.swift:20`: the Groups roster is built from fixture members on every store | FALSE today. Needs a server-backed roster (accepted A1) |
| P2 | Connecting shares "name and status" | Accept screen, Visibility contract | `GroupsSession.swift:5`: statuses live in memory on one device; no statuses table in `supabase/` | Name: true after T1. Status: nothing to share yet (taste d1, TODO) |
| P3 | Sender gets a push when away | Sender arrival, T1 `friend_joined` | `social.sql:33` names `supabase/functions/push-notify`; the directory is not in the repo and the live project lists zero Edge Functions (Supabase `list_edge_functions`, 2026-11-10) | FALSE today. Rows are queued and never sent; this also means poke pushes do not arrive (A11, TODO) |
| P4 | `push_outbox` can carry a new kind | "new `friend_joined` kind" | `social.sql:98`: `check (kind in ('poke', 'tag_along'))` inside `create table if not exists` | True only with a constraint swap that also runs on the upgrade lane (A4) |
| P5 | Friends can Poke | Visibility contract | `social.sql:185`: the gate is `friendcal_share_plan` only | FALSE until the gate is widened (A3) |
| P6 | Reuse `DeepLink` + sanitizing | What already exists | `DeepLink.swift:17`: one case, `.proposal`; custom scheme only (`DeepLink.swift:5`) | True for the sanitizer; the enum and the URL forms are new work |
| P7 | Auth preserves the pending invite | Accept screen | `FriendCalApp.swift:85`, `:118`: `FriendCalPendingLink` is stored and replayed once after sign-in | True; reuse it |
| P8 | A universal link, AASA and landing are buildable now | T4 | `TODOS.md:170`: "Depends on: ... owning friendcal.app; a public TestFlight link"; `FriendCal.entitlements` has no associated domains; `CLAUDE.md:35`: external testers need Beta App Review | UNVERIFIED: the repo cannot show whether the domain is owned (gate question) |
| P9 | The wheel shows the new friend's face | Sender arrival, T5 | `HomeView.swift:116`: the wheel draws `session.wheel.faces`, the current plan's members | UNVERIFIED, likely false; owned by the Eng phase |
| P10 | A short code recovers the invite on first launch | Web landing, T4 | No screen, table column or RPC for a code anywhere in the plan | Under-specified (pending U1) |
| P11 | "Friends who open it can ask to connect" | Sheet subtitle | Accept screen: the recipient taps Connect and the pair is connected; no sender step exists | Copy contradicts the flow (taste d2) |

unverified=2 (P8, P9).

#### 0B. Existing code leverage
| Sub-problem | Existing code | Reuse |
|---|---|---|
| Friend graph gate for Poke | `friendcal_share_plan` + `send_poke` (`social.sql:136`, `:161`) | Extend the gate; do not add a second poke path |
| Reading a friend's name | `users_read_self_and_co_participants` (`users_auth.sql:28`) | Add one `or` branch |
| Push to the sender | `push_outbox` + compose-in-transaction rule (`social.sql:32`) | Same pattern; new kind |
| Link parsing and outside-text safety | `DeepLink.parse` / `sanitizedTitle` (`DeepLink.swift:33`, `:60`) | Add a `.friend` case; same sanitizer for the name hint |
| Sign-in round trip | `FriendCalPendingLink` (`FriendCalApp.swift:85`) and the invited pill (`AuthGateView.swift:168`) | Reuse; the pill text needs a friend variant |
| Share text | `ShareText.invite` (`ShareText.swift:18`) | Add `friendLink` beside it |
| Push routing | `PushRoute` + `AppTabView.follow` (`PushRoute.swift:8`, `AppTabView.swift:104`) | Add a case |
| Store seam and test doubles | `ProposalStore` (`ProposalStore.swift:122`), `InMemoryProposalStore.friendIDs` (`:31`) | Add methods; `friendIDs` becomes the in-memory friendships table |
| Entry points | `InviteSeatCard` (`GroupsParts.swift:117`), wheel pill (`FriendsWheel.swift:65`), Moments `.invite` action (`Moments.swift:9`) | Rename and wire; no new components |
Nothing is being rebuilt. The plan's reuse list is right and misses the store seam, `PushRoute` and `send_poke`.

REALITY: premise-table finding 11 premises checked, 3 false today (P1, P3, P5), unverified=2 docs/designs/friendcal-add-friend.md:17
REALITY: already-done pass no friend-link or friendships work on origin/main as of 95093af 95093af
REALITY: surface-check finding the plan names push-notify delivery and a universal link; neither surface exists (no supabase/functions, no associated domains) supabase/social.sql:33
REALITY: binding-decisions pass gstack-decision-search returned no branch decisions; the 1A/1B/3A/7A design decisions in the plan are treated as binding and none is overruled docs/designs/friendcal-add-friend.md:8
REALITY: numbers pass the plan's only numbers are effort estimates [estimated] and the 7-day expiry, a product choice docs/designs/friendcal-add-friend.md:60
REALITY: deferred-asks pass no linked issue; the plan's own deferral (VoiceOver announcements) has no TODOS.md entry and gets one docs/designs/friendcal-add-friend.md:57
REALITY: pr-count finding no .gstack/ship-policy.json, default is one PR; this plan is three independently shippable slices (SQL, app, web+AASA) and the web slice is blocked on a domain supabase/social.sql:98
REALITY: transaction-semantics pass no driver, pool or protocol change; the new functions run in one transaction each and take the existing advisory-lock order (R26) supabase/lock_proposal.sql:32

#### 0C. Dream state
```
CURRENT STATE                      THIS PLAN (as amended)               12-MONTH IDEAL
Friends = people you already       A real friendships table, one        Open the app, the wheel and Groups
share a plan with. Groups roster   link to share, an explicit accept,   show your actual 10-20 people, live:
and statuses are fixtures on one   remove a friend, Groups roster read  status, free/busy, pokes that arrive.
device. Invite buttons are         from the server, Poke gated on       New people join from any link in one
toasts. Pushes are queued and      friendship. Status and push          tap, installed or not. Crews are
never sent.                        delivery still latent.               saved and feed plan recipients.
```
The plan moves toward the ideal and is the right first step: the friend graph is the read gate every later piece (statuses, crews, wheel) needs. It leaves three holes the ideal depends on: statuses on the server, the push forwarder, and crews on the server.

#### 0D/0E. Approach and mode
No approach choice was open: the link model (1B), explicit accept (3A) and the visibility contract (7A) are the user's design-review decisions and stand. Mode: SELECTIVE EXPANSION (added capability on shipped code; /autoplan override). Planned changed files are roughly 22 [estimated]: 3 SQL + 2 SQL tests + test-sql.sh, about 12 Swift, project.yml/entitlements, 3 web. That is over the 15-file line that would normally suggest reduction; the plan is kept whole because it already splits into three slices that ship separately (see 0I).

#### 0F/0G. Hold-scope checks and cherry-picks
Complexity check: the SQL adds two tables and five RPCs; the app adds one sheet, one QR sheet, one accept screen and store methods. Nothing can be dropped without losing a stated outcome, except the web slice, which can ship later without blocking the rest (A9).

| # | Proposal | Kind | Effort (human / CC) | Decision | Principle and reason |
|---|---|---|---|---|---|
| A1 | Groups roster read from the server (`friends()` on the store; `GroupsSession` fed from it on the real store) | Required repair | M / S | ACCEPTED | P1: without it a connected friend never appears (P1 premise false) |
| A2 | Store seam: `friendLink`, `resetFriendLink`, `previewFriendLink`, `acceptFriendLink`, `friends`, `removeFriend` on `ProposalStore`, both stores, `UserFacingError` hints, UI-test launch arguments | Required repair | M / S | ACCEPTED | P1: T2/T3 have nothing to call otherwise |
| A3 | `send_poke` gate becomes "friends, or share a plan"; refusal copy updated | Required repair | S / S | ACCEPTED | P1: the contract says friends can Poke |
| A4 | `push_outbox_kind` constraint swap that runs on fresh and upgraded schemas; `PushRoute.friendJoined`; shell routes it to Groups; `-FriendCalPushTap friend/<uuid>` | Required repair | S / S | ACCEPTED | P1 |
| A5 | Remove a friend: `remove_friend` RPC and a quiet action with a confirm on `FriendCard` | Expansion | S / S | ACCEPTED | P2: in blast radius, under a day. A reusable link with no way to undo a connection is the one-way door in this plan |
| A6 | `delete_account()` also removes the person's friendships and link | Required repair | S / S | ACCEPTED | P1: a tombstone must not stay someone's friend |
| A7 | Link contract written down: unguessable token, one row per user, uniform "expired" answer, idempotent accept, inviter name on the accept screen comes from the server | Required repair | S / S | ACCEPTED | P5: explicit beats discovered in review |
| A8 | Web landing renders the name hint as text only, capped | Required repair | S / S | ACCEPTED | P1: a query-string name on our own domain is attacker text |
| A9 | `DeepLink` accepts `friendcal://friend/<token>` as well as the https form, so the SQL and app slices ship before the domain exists | Sequencing | S / S | ACCEPTED | P6: do not block four tasks on DNS |
| A10 | T4 prerequisites listed in the plan (domain, host, AASA app ID, entitlement, public TestFlight link) | Required repair | S / S | ACCEPTED | P5 |
| A11 | Push forwarder Edge Function | Expansion | L / M | DEFERRED to TODOS.md | P2/P3: new infrastructure (function, APNs key, schedule). The outbox row is still written, as for pokes |
| E8 | Statuses on the server, read-gated by friendship | Expansion | L / M | DEFERRED to TODOS.md | P2: more than 5 files and a new table; this plan is its prerequisite |
| E4 | "N friends joined with this link" on the sheet | Expansion | S / S | DEFERRED to TODOS.md | Changes an approved mockup; design call, not a repair |
| E10 | Block a person | Expansion | M / S | DEFERRED to TODOS.md | Remove + Reset link cover v1 for a known group |
| E11 | TODOS.md entry for the user-deferred VoiceOver announcements | Bookkeeping | S / S | ACCEPTED | The plan says "see TODO" and no TODO exists |
| S1 | Sender approves each request | Alternative | M | SKIPPED | Contradicts 1B (no pending rows), the user's decision |
| d1 | Keep "and status" in the accept line | Taste | none | KEEP (recommended), surfaced at the gate | Consent that already covers status means no re-consent when statuses sync; the cost is a promise the app cannot keep yet |
| d2 | Sheet copy "can ask to connect" becomes "can connect with you" | Taste | S | CHANGE (recommended), surfaced at the gate | P5: nobody is asked; the sender should know the link is instant |
| d3 | T4 also serves plan links at `/p/<id>` (closes `TODOS.md:160`) | Taste, borderline scope | S / S | INCLUDE (recommended), surfaced at the gate | P2/P4: one AASA, one landing, one parser |
| U1 | Short-code recovery on first launch | Pending | | UNRESOLVED until both voices report | The user chose it (3B); it is unspecified and a short code is guessable |

<!-- autoplan-accepted:ceo -->
- A1 Groups roster. `ProposalStore` gains `friends()` returning the caller's friends (id, name, avatar). On the Supabase store, Groups lists exactly those people plus the caller; fixture seeding stays for the in-memory store and UI tests. A friend who connects appears in "Friends on FriendCal" after the next refresh (foreground, pull, or push arrival). Test: a core test that `GroupsSession` built from a store with two friendships lists two friends; a UI test that accepting a link in the in-memory store adds the row.
- A2 Store seam. `ProposalStore` gains `friendLink()` (get or mint), `resetFriendLink()`, `previewFriendLink(token:)`, `acceptFriendLink(token:)`, `friends()`, `removeFriend(_:)`. `InMemoryProposalStore` implements them row for row with the SQL (its `friendIDs` set becomes the friendships table). `UserFacingError` maps each new hint to one sentence. New launch arguments make each recipient state reachable in UI tests and are documented in CLAUDE.md. Test: `swift test` covers every refusal; `-FriendCalFailNext` covers link fetch, reset and accept.
- A3 Poke gate. `send_poke` allows the poke when the two people are friends or share a plan neither is hidden from. Every other case keeps the single `FC_NOT_FRIEND` refusal. The sentence shown becomes "You can only poke friends." Test (SQL, through `t.*`): friends with no shared plan can poke; after `remove_friend` they cannot; a stranger still gets `FC_NOT_FRIEND`.
- A4 Push kind. `push_outbox` accepts `friend_joined` on a fresh schema and on one upgraded from `origin/main` with rows present. `PushRoute` parses it; the shell opens Groups. `-FriendCalPushTap friend/<uuid>` stands in for the tap. The row is written to the inviter when someone accepts their link, never to a deleted account. Test: SQL test on both schema lanes; `PushRoute` unit test; UI test for the tap.
- A5 Remove a friend. `remove_friend(p_user)` deletes the pair, is idempotent, tells the other person nothing and writes no push. After it, neither can read the other's name through friendship or poke through friendship; anything a shared plan grants is unchanged. `FriendCard` shows a quiet "Remove friend" with a confirm dialog; no coral. Test: SQL test for both directions and idempotency; UI test for the confirm and the row leaving.
- A6 Deletion. `delete_account()` deletes the caller's friendships and `friend_links` row in the same transaction. Test: SQL test that a deleted account is nobody's friend and its old link answers "expired".
- A7 Link contract. The token is at least 128 bits from a CSPRNG, URL-safe. One `friend_links` row per user. Reset replaces the token and the expiry. Preview and accept take only the token and read `auth.uid()`. An unknown, reset, expired or deleted-inviter token all return the same "expired" answer. Accept is idempotent (double tap, both people accepting each other's link, retry after a dropped response all end with one friendship). A friendship is one row per unordered pair. Own link and already-friends are distinct, non-error answers. The accept screen shows the inviter name the server returned, never the URL hint. Guards on nullable booleans use `is not true` (learning `plpgsql-if-not-null-fails-open`). Test: SQL tests for each answer, using `t.uh(n)` ids for any case-sensitive comparison.
- A8 Landing text safety. The landing page writes the name hint with `textContent`, after the same sanitizing rules as `DeepLink.sanitizedTitle`, capped at 40 characters, and falls back to "A friend". No `innerHTML`, no hint in any attribute or URL. Test: a page test (or manual checklist item) with `<img onerror>` and a bidi override in the hint.
- A9 Two link forms. `DeepLink` parses `friendcal://friend/<token>?n=<hint>` and `https://<domain>/f/<token>?n=<hint>` into the same case. Until the domain is live the app shares the custom-scheme form; T4 flips one constant. T1, T2, T3, T5, T6 do not depend on T4. Test: `DeepLink` unit tests for both forms and for malformed tokens.
- A10 T4 prerequisites, stated in the task: the domain is owned and serves HTTPS; a static host; `apple-app-site-association` with app ID `6589A6M74D.com.friendcal.app`; `com.apple.developer.associated-domains` in `app/project.yml` followed by `xcodegen generate`; a public TestFlight link (needs Beta App Review) as the "Get FriendCal" target. T4 does not start until the first is true.
- E11 Add the TODOS.md entry "Custom VoiceOver announcements for Link copied and friend joined" that the plan already points to.
- Deferred, each with a TODOS.md entry written at approval: push forwarder Edge Function (A11); statuses on the server gated by friendship (E8); link join count on the sheet (E4); block a person (E10).
- R1 (refines A5) Remove and the link. Removing someone does not stop them reconnecting with a link they still hold. The confirm dialog says so and offers three choices: "Remove", "Remove and reset link", "Cancel". The second calls remove then reset. Test: UI test for each choice; SQL test that a removed person can accept again unless the link was reset.
- R2 (refines A7) Access to the new tables. `friendships` and `friend_links` have row level security on, no client grants and no client policy; every read and write goes through a definer function. Both tables are added to the RLS-on guard list in `supabase/rls.sql` and the new SQL file is added to `WAVE_SQL` in `scripts/test-sql.sh` and to the README apply order. A token is never returned to anyone but its owner. Test: `t.*` assertions that an authenticated client reads zero rows from both tables; the self-check fails if RLS is off.
- R3 (refines A4) One push per new friendship. The `friend_joined` row is written only when accept inserts a new friendship row, never on a repeat accept. Title "<joiner name> joined FriendCal", body "You two are connected.", data `{"kind":"friend_joined","user_id":"<joiner id>"}`, no expiry. `-FriendCalPushTap friend/<uuid>` carries the joiner's id; the shell opens Groups and highlights that row. Test: SQL test that a second accept writes no second row.
- R4 (clarifies the Visibility contract) Friendship grants no plan access. "Tag along to plans the host shares with them" describes existing behavior: a friend sees only plans they are already a recipient of. No proposals, busy_blocks, places or tag_alongs policy changes in this plan. Test: SQL test that a friend who is not a recipient reads zero rows of the other's plans and that `hidden_from` still returns "no such plan".
- R5 (refines A7) Where the name hint may show. The Connect screen and its button use the server's inviter name. The URL hint may be shown only where no server name exists: the sign-in pill and the expired state ("Sam's link has expired"). With no usable hint these read "You were invited to connect" and "This link has expired. Ask your friend for a new one."
- R6 (clarifies T1) The `users` change is one added `or` arm on the existing read policy: the two people are friends. Column grants are not touched (`id, display_name, avatar_url, deleted_at`). Status is not a `users` column and is not part of T1; it arrives with the deferred statuses backend (E8).
- R7 (refines A8, A9) One cap for the name hint `n`: 40 characters, in the app parser, the share text and the landing page. A token is 22 to 64 characters of `[A-Za-z0-9_-]`; anything else parses to no link and shows the existing "That link isn't a FriendCal invite" toast. `DeepLink.proposalID` and `DeepLink.title` become optional or move onto the case, and their call sites (`AppTabView.open`, `FriendCalApp` pending-link replay, `AuthGateView` pill) are updated in T3. The landing-page safety check is a manual checklist item in T4 with the two listed inputs.
- R8 (refines A1) `GroupsSession` gains a store reference and an async `refresh()` that replaces `friends` from `store.friends()`; the shell calls it on appear, on foreground and when a push arrives. On the Supabase store, statuses and busy time start empty and crews stay on the device, filtered to current friends (a crew member who is no longer a friend is dropped from display). The row-appears UI test lives in T5 only. Effort re-estimated: human ~1d / CC ~45min.
- R9 (refines A9, A10) Until T4 ships, a friend link only works for someone who already has the app; the share text is unchanged and the Add a friend sheet makes no not-installed promise. The domain is `friendcal.app` (the one `TODOS.md:160` and the mockups name) with path `/f/<token>`; `/p/<id>` joins only if taste decision d3 is approved.
- R10 (resolves the wheel claim) The Home wheel draws the current plan's members. When there are none, it draws the caller's friends instead (same 10-face cap and overflow drawer), so "Add your first fave" disappears once a friend connects. With plan members present the wheel is unchanged. Test: core test for the face source in both cases; UI test that the empty state goes away after an accept.
- R11 (refines R8) Noticing a new friend. `refresh()` compares the returned ids with a per-account set saved on the device. Ids not in the set produce the "Jess joined" Moments line, the success haptic and the row highlight, then join the set. The first load for an account fills the set silently. Test: core test for first load, one new friend, and a removed friend (no announcement).
- R12 (refines A6, A7) Accept under concurrency. Accept takes the shared per-user lock (`friendcal_lock_users`) on both people, then re-reads the token row and both accounts' active state before inserting. `delete_account()` includes the caller in the ids it locks. A link reset or account deletion that commits first makes the accept answer "expired"; one that commits second removes the friendship it finds. Test: SQL test for each order using two sessions or the existing lock-order pattern.
- R13 "Not now" and the pending slot. "Not now" clears the pending friend link and returns to where the person was; the link still works if opened again. The app keeps one pending link: the most recently opened wins, whichever kind it is. Test: UI test that "Not now" does not reappear on next launch.
- R14 (refines A2) `friendLink()` returns the caller's row as it is, including an expired one with its expiry, and mints only when the caller has no row. "Make a new link" and "Reset link" both call `resetFriendLink()`. `friends()` is a definer function (`my_friends()`) returning id, name, avatar and the time connected. Launch arguments: `-FriendCalFriendLink valid|expired|own|already` sets what the in-memory store answers for the opened token; `-FriendCalFailNext` gains `friendLink`, `resetFriendLink`, `acceptFriendLink`, `removeFriend`.
- R15 (refines R7) `DeepLink.sanitizedTitle` takes the length cap as a parameter: 80 for plan titles as today, 40 for the name hint.
- R16 The link preview (landing title and share image) in the Share message section is part of T4 and does not exist before it.
- R17 (refines R2, R6) Where the SQL lives. `friendships`, `friend_links` and the helper `friendcal_is_friend(p_other uuid)` go in `supabase/schema_additions.sql`, which runs first, so the `users` policy in `users_auth.sql`, `send_poke` in `social.sql` and `delete_account()` are each changed in place, in the file that already owns them. The helper is a definer function that takes only the other person's id and reads `auth.uid()` itself, so it cannot answer whether two other people are friends; the policy arm calls it. A new `supabase/friends.sql`, applied last (after `social.sql`), holds the link and friend functions, the `push_outbox` kind swap and the self-check. The Eng phase may move pieces, but not duplicate a function body in two files.
- R18 (replaces R1's two calls) `remove_friend(p_user uuid, p_reset_link boolean default false)` does both in one transaction; "Remove and reset link" passes true.
- R19 (narrows A4, R3) The server side stays: the kind swap and one outbox row per new friendship. The client side (a `PushRoute` case, shell routing, the `-FriendCalPushTap friend/<uuid>` argument) moves to the deferred push forwarder TODO, because nothing can deliver that push yet. An app that later receives the unknown kind simply opens.
- R20 T1 re-estimated with A3, A6, A7, R2, R12, R17: human ~2d / CC ~2h.
- R21 (refines R9) A `friendcal://` link is not reliably tappable in Messages and is not a link at all to someone without the app. Before T4 the feature is for people who have the app and mainly through the QR code; it is not announced as "send a link to anyone" until T4 ships. T4 stays P1.
- R22 (refines R3) The `friend_joined` outbox row expires 24 hours after it is written, so a forwarder that ships later never sends a stale "joined" push.
- R23 The cached link on the sheet is stored per account and cleared on sign-out and on account deletion. Test: core or UI test that a second account never sees the first account's link.
- R24 (corrects R12) Only account deletion removes friendships. A link reset never removes one: an accept that committed before the reset stays connected, matching the Reset dialog's promise. An accept that reaches the server after the reset answers "expired".
- R25 (refines R11) The saved set. It is first filled by the first roster load after sign-in, and "never loaded" is a different state from "loaded and empty", so a new user's first friend is announced. When the recipient accepts, the inviter's id goes into the recipient's set at once, so the recipient sees only "You and Sam are connected", not a second "Sam joined". An id that disappears from the roster leaves the set, so reconnecting after a removal announces again.
- R26 (refines R12, R18) Locks. Accept, `remove_friend` and the link reset all take `friendcal_lock_users` on the people involved. Accept checks account state with `is_active()` and takes no `users` row lock, so it cannot reverse `delete_account()`'s order (row lock, plan locks, then user locks).
- R27 (replaces R1 and R18) Removing someone also stops them reconnecting. `remove_friend(p_user)` deletes the pair and records that the caller removed that person. A later accept of the caller's link by that person gets the same "expired" answer as any dead link. The record is cleared only when the caller accepts that person's link. The dialog is one confirm: "Remove Sam? Sam won't be able to reconnect with your link." No three-choice dialog and no reset flag. Test: SQL test that the removed person's accept answers "expired" before and after a link reset, and that the remover accepting the other's link reconnects them.
- R28 (replaces the release order in R21) Rollout order. The entry points (T6) merge last, together with T4, so nobody is offered "Add a friend" while the link is dead for people without the app. Until then the sheet is reachable from the debug sheet only. The T4 prerequisites in A10 start on day one, in parallel with T1.
- R29 Counting. `friend_links` keeps `accept_count` and `last_accepted_at`; `friendships` keeps `created_at`. The README gains one saved query that reports links minted, accepts, friends per person, and new friendships followed by a shared plan within 7 days. No UI. Proposed measure, for the owner to confirm: within 14 days of T4, half of testers have at least one friend.
- R30 Two factual corrections to the plan text. (1) Screen 5: `FriendCard` has Poke and Tag along; it has no "Start a plan" action (`FriendCard.swift:6`), so the card opens with the two that exist. (2) Visibility contract: every signed-in person can already read anyone's Busy times as plain blocks with no detail (`rls.sql:41`, `:379`); friendship adds a readable name beside them and nothing else. Test: SQL test that a friend reads a Busy block's time and none of its hidden columns.
- R31 Before implementation starts, the accepted items are folded into the plan body as one spec and the sentences they supersede are removed, so nobody builds from the stale half.
- R32 (refines R8) When a roster refresh fails, Groups keeps showing the last roster it loaded and retries quietly on the next foreground; it never swaps to an empty list or the "no friends" state because of an error. A first load that fails shows the existing inline error with Retry. Test: core test that a throwing store leaves `friends` unchanged.
<!-- /autoplan-accepted:ceo -->

Spec review 3 (2026-11-10, the last allowed): 6/10, 9 issues, Scope passed. All 9 applied as R22-R26 and one summary wording fix. Issues verified: 9 of 9 edits applied to the plan text; the amended spec was not re-reviewed (review cap), so these are applied edits, not a reviewer verdict.

Spec review 2 (2026-11-10): 6/10, 17 issues. 16 fixed by R10-R21 above; 1 was an artifact of the review export (the reviewer saw the plan without its section headings). The contract's "Groups status/presence" wording stays until taste decision d1 is settled at the gate.

Spec review 1 (2026-11-10): 5/10, 19 issues. 15 fixed by R1-R9 above. Left for the final gate because they are the user's calls: short code (U1), "ask to connect" copy (d2), plan links in T4 (d3, the reviewer would defer it), "and status" in the accept line (d1, the reviewer would drop it).

#### 0I. Temporal interrogation
```
HOUR 1 (foundations)   Where does the SQL live? A new supabase/friends.sql applied after social.sql
                       (scripts/test-sql.sh:63, README apply order). It must change a policy that lives in
                       users_auth.sql and a function that lives in social.sql. Decide: edit in place, or
                       re-create from friends.sql. (Eng phase.)
HOUR 2-3 (core)        What does accept return for each state, and which is an error versus a value?
                       Does a 7-day expiry mean "minted 7 days ago" on the server clock? (Yes; the sheet
                       shows the server's expires_at.)
HOUR 4-5 (integration) The Groups roster is fixtures. The wheel is the plan's members, not friends.
                       FriendCalPendingLink replays a plan link into the Invites tab; a friend link must
                       route to the accept screen instead.
HOUR 6+ (polish)       Every recipient state needs a launch argument or the UI tests cannot reach it.
                       The landing page needs a real device with and without the app; the simulator does
                       not exercise AASA the same way.
```
Slices and effort: (1) SQL: human ~1.5d / CC ~1.5h. (2) App, custom-scheme links: human ~2.5d / CC ~2h. (3) Web + AASA + universal link: human ~1d / CC ~1.5h, blocked on the domain.

#### Step 0.5: two independent voices (run on the amended plan, snapshot 6823801c)
Claude subagent: completed, 11 findings (2 critical, 4 high, 4 medium, 1 low-medium). Codex (gpt-6-astra, outside): completed, 8 findings (7 high, 1 medium), verdict FINDINGS.

```
CEO DUAL VOICES — CONSENSUS TABLE
  Dimension                             Claude    Codex     Consensus
  1. Premises valid?                    No        No        CONFIRMED concern
  2. Right problem to solve?            Yes, but  Yes, but  CONFIRMED: plan-first is the stronger loop
  3. Scope calibration correct?         No        No        CONFIRMED concern (payoff under-built)
  4. Alternatives sufficiently explored? No       No        CONFIRMED concern
  5. Competitive/market risks covered?  No        No        CONFIRMED concern
  6. 6-month trajectory sound?          At risk   At risk   CONFIRMED concern
```

| Theme | Claude | Codex | Disposition |
|---|---|---|---|
| The share message says "see when you're both free" and the accept line says "status"; neither ships | #2 critical | #1 high | USER CHALLENGE UC1 (your 7A/7C copy) |
| "Ask to connect" is false; the link connects at once | #4 high | #3 high | USER CHALLENGE UC2 (your 5A copy). Codex also wants inviter approval; that contradicts 1B and is not proposed |
| Friendship should come from joining a plan, with the link as the second path | #3 high | #2 high | USER CHALLENGE UC3 (adds a feature) |
| Short code: long funnel, no design, guessable | #5 high | #5 (partial) | USER CHALLENGE UC4 (your 3B decision) |
| 7-day expiry on a reusable link has no stated benefit | #7 medium | #8 medium | USER CHALLENGE UC5 (your 1B decision) |
| Do not offer the feature before the link works for people without the app | #1 critical | #5 high | ACCEPTED R28 |
| Removal needs to stick; block before wider sharing | #4 | #3 | ACCEPTED R27 (reverses my deferral of E10 for the remove case) |
| No success measure | #6 high | #7 high | ACCEPTED R29 |
| Push delivery matters more than this plan assumes | #8 (counterpoint) | #6 high | TASTE d4: I keep it a separate plan, started next |
| Busy times become attributable to a named friend | not raised | #4 high | ACCEPTED R30 (contract corrected); verified at `rls.sql:41` |
| "Start a plan" is not an existing FriendCard action | not raised | #1 | ACCEPTED R30; verified at `FriendCard.swift:6` |
| The plan is a pile of patches | #9 medium | not raised | ACCEPTED R31 |
| Cut the outbox kind, the wheel fallback and the two-session tests | #8 medium | not raised | Not taken: each is small and closes a stated outcome. The three-choice dialog is gone (R27) |
| Plan links at `/p/<id>` in T4 | #1 (include) | not raised | TASTE d3 stays: include |
| Browser or non-iOS participation; "friends already here" discovery | #11 | #5 | Out of scope, noted below |

#### Section 1: Architecture
```
 SENDER PHONE                         SUPABASE                               RECIPIENT PHONE
 Groups "+" / wheel / seat card                                              link tap or QR scan
        │                                                                          │
        ▼                                                                          ▼
 AddFriendSheet ── friendLink() ──▶ friend_link()  ──▶ friend_links (1 row/user)   DeepLink.parse(.friend)
        │         resetFriendLink()   reset_friend_link()                          │  (not signed in: pending
        │                                                                          ▼   link + AuthGate pill)
   ShareLink / QR ─────── https://friendcal.app/f/<token>?n=Sam ─────────▶ AcceptView
        ▲                 (friendcal://friend/<token> until T4)                    │ previewFriendLink(token)
        │                                                                          ▼
 GroupsSession.refresh() ◀─ my_friends() ◀── friendships (1 row/pair) ◀── accept_friend_link(token)
   diff vs saved set                 │        friend_removals (R27)               │
   Moments + haptic + row            ├──▶ push_outbox (friend_joined, 24h)        ▼
        │                            │        └─▶ [push forwarder: NOT BUILT]   Groups, row highlighted
        ▼                            ├──▶ users read policy  (+ friendcal_is_friend arm)
   FriendCard: Poke ─ send_poke ─────┴──▶ send_poke gate     (+ friendcal_is_friend)
               Remove ─ remove_friend           delete_account() (+ clears friendships, link)

 friendcal.app (static, T4): /.well-known/apple-app-site-association, /f/* landing ──▶ TestFlight link
```
- Boundaries: the app talks to the server only through `ProposalStore`; every new write is a definer function with no user parameter; the two new tables have no client access (R2). This matches `social.sql`. No new coupling except `GroupsSession` gaining a store reference (R8), which it should have had.
- Data flow, four paths for accept: happy (token valid, pair inserted, one push row). Nil (no token in the URL: parse returns nil, existing toast). Empty or dead token (unknown, reset, expired, deleted inviter, or removed by the inviter: one "expired" answer). Error (network: inline error and Retry, the pending link is kept).
- State machine for a link: `none ──friendLink()──▶ live ──7 days──▶ expired ──reset──▶ live`; `live ──reset──▶ live (new token)`. No transition returns an old token to life. State machine for a pair: `strangers ──accept──▶ friends ──remove──▶ removed(by A) ──A accepts B's link──▶ friends`; `friends ──either deletes account──▶ strangers`.
- Scale: 10 to 20 friends each; `my_friends()` is one indexed read. Nothing here breaks at 100x.
- Single points of failure: the static host for T4 (a dead host turns every shared link into a browser error; the custom scheme and QR keep working for installed users) and Apple's AASA cache (changes take hours to days to reach devices).
- Rollback: the SQL is additive and idempotent; leaving it applied is harmless. The app rolls back by shipping the previous build. The domain can be pointed away without touching the app because both link forms parse (A9).
- **WARNING** (accepted R28): the first shippable slice only works between installed users. **WARNING** (taste d4): no push delivery exists, so the sender learns of a new friend only by opening the app.

#### Section 2: Error and rescue map
| Codepath | What can go wrong | Refusal | Rescued | User sees |
|---|---|---|---|---|
| `friend_link()` / sheet open | offline, timeout | transport error | Y: cached link shown, quiet retry | Cached link; first-ever open shows "Couldn't get your link" + Retry |
| | signed out, deleted account | `FC_NOT_SIGNED_IN`, `FC_ACCOUNT_DELETED` | Y: existing auth handling | Sign-in gate |
| `reset_friend_link()` | offline | transport | Y | Inline error + Retry; old link still shown |
| `preview_friend_link(token)` | dead token (5 causes) | value `expired` | Y | "Sam's link has expired" (hint) or the nameless line (R5) |
| | own link | value `own` | Y | "This is your link" + Share |
| | already friends | value `already` | Y | "You and Sam are already connected" + Open Groups |
| | offline | transport | Y | Inline error + Retry; pending link kept |
| `accept_friend_link(token)` | double tap, retry after dropped response | none (idempotent) | Y | One connection |
| | link reset or inviter deleted between preview and accept | value `expired` | Y | Expired state replaces the Connect screen |
| | removed by the inviter (R27) | value `expired` | Y | Same expired state; nothing reveals the removal |
| `remove_friend(p_user)` | offline | transport | Y | Row stays; toast with the mapped sentence |
| | not a friend any more | none (idempotent) | Y | Row leaves |
| `my_friends()` / Groups refresh | offline | transport | **GAP** | Unspecified: the roster needs a stale-but-shown state and a quiet retry, not an empty list |
| `DeepLink.parse` | malformed token, wrong host | nil | Y | "That link isn't a FriendCal invite" |
| Landing page (T4) | host down, AASA not yet propagated | n/a | N | Browser error, or the page opens when the app is installed. Covered by the T4 manual check only |
| `send_poke` to a friend | not friends any more | `FC_NOT_FRIEND` | Y | "You can only poke friends." |
One gap: the Groups refresh failure state. Auto-decided (P1): accepted as part of R8, see the CEO block addendum below.

#### Section 3: Security and threat model
| Threat | Likelihood | Impact | Mitigated |
|---|---|---|---|
| A forwarded or leaked link lets strangers connect, read name and avatar, see Busy times with a name, and poke | Med | Med | Partly: Reset link, Remove that sticks (R27), honest copy if UC2 is approved. No approval step by design (1B) |
| Token guessing | Low | Med | Yes: 128-bit token (A7). A short code would undo this (UC4) |
| Probing whether an account exists or a link was reset | Low | Low | Yes: one "expired" answer for every dead case (A7, R27) |
| Reading tokens or the friend graph from a client | Low | High | Yes: no client grants, RLS on, self-check (R2) |
| "Are A and B friends" oracle through the policy helper | Low | Med | Yes: helper takes only the other id (R17) |
| Name hint used for script injection or spoofed text on friendcal.app | Med | Med | Yes: text only, sanitized, 40 characters (A8, R7) |
| Friendship widening plan or stealth access | Low | High | Yes: no plan policy changes; SQL test (R4) |
| Deleted account stays reachable as a friend | Low | Med | Yes (A6, R12) |
| Poke spam from an unwanted friend | Med | Low | Yes: one live poke per pair per hour already; Remove ends it |
No new secrets or dependencies. The APNs key belongs to the deferred forwarder. Audit trail: `friendships.created_at`, `friend_links.accept_count` (R29); no log of failed accepts, which is acceptable at this scale.

#### Section 4: Data flow and interaction edge cases
```
URL ─▶ DeepLink.parse ─▶ pending slot ─▶ (sign in) ─▶ preview ─▶ Connect tap ─▶ accept ─▶ Groups
 │         │                  │                          │            │            │
 nil    bad token:        overwritten by a            expired/      double tap:   refresh fails:
 URL    toast, drop       newer link (R13)            own/already   idempotent    stale roster (gap, now R8)
```
Shared mutable state and ordering. Invariant: a pair is friends only if both accounts are active and the accept began on a live token. Schedule, both orders, all three writers take `friendcal_lock_users` (R26):
```
 accept(B on A's link)        reset(A) or delete(A)        friendships
 lock users {A,B}             waits                        -
 re-read token, is_active     waits                        -
 insert pair, commit          runs: reset keeps the pair   A-B            (R24: stays)
                              delete removes the pair      -              (A6)
 ---- other order ----
 waits                        lock, reset/delete, commit   -
 lock, re-read token: dead    -                            -              answer "expired"
```
Both orders meet the invariant because the token and account are re-read after the lock. Regression proof: the two-session SQL test in R12.

| Interaction | Edge case | Handled | How |
|---|---|---|---|
| Copy | tapped twice | Y | label swap is idempotent |
| Share | sheet dismissed mid-share | Y | native `ShareLink` |
| Reset link | double confirm, offline | Y | one call; inline error |
| Connect | double tap, app killed mid-call | Y | idempotent accept; pending link kept until an answer arrives |
| Connect | opened own link, already friends | Y | distinct states |
| Not now | relaunch | Y | pending link cleared (R13) |
| Link opened while signed out | sign-in, then name prompt | Y | existing replay (`FriendCalApp.swift:118`), routed to Accept |
| Two links opened in a row | plan then friend | Y | most recent wins (R13) |
| Roster | friend removed elsewhere, zero friends, 50 friends | Y | refresh replaces the list; empty state exists; list scrolls |
| Arrival | several friends join between opens | Partial | R11 announces ids; the Moments line for more than one is unspecified (Design phase) |

#### Section 5: Code quality
The plan fits the repo's patterns: definer RPC per action, named hints, one store seam, in-memory mirror. Duplication risk: the friend check must exist once (`friendcal_is_friend`) and be called from the policy, `send_poke` and the accept path; R17 says so. `DeepLink` moves from one case to two, so `proposalID` and `title` stop being total (R7); this is the one place existing call sites change shape. No over-engineering remains after R27 removed the three-choice dialog. Under-engineering: none beyond the roster error state. No method in the plan needs more than five branches; accept's answers are a four-value enum.

#### Section 6: Tests
```
NEW THING                                   TEST TYPE        HAPPY            FAILURE                  EDGE
friend_link / reset                         SQL (t.*)        mint, reset      signed out, deleted      expired row returned as-is (R14)
preview / accept                            SQL (t.*)        connect          every dead-token cause   own, already, double accept, t.uh ids
accept vs reset / delete                    SQL two-session  -                -                        both commit orders (R12, R24)
remove_friend (+ sticks)                    SQL              remove           -                        idempotent, re-accept answers expired (R27)
users policy arm, poke gate                 SQL (t.*)        friend reads     stranger refused         removed friend loses both
no plan or stealth widening                 SQL (t.*)        -                friend reads 0 plans     hidden_from still "no such plan" (R4)
tables locked down                          SQL (t.*) + self-check            client reads 0 rows      RLS off fails the file (R2)
push_outbox kind on both schema lanes       SQL upgrade lane one row          repeat accept: no row    24h expiry (R22)
delete_account clears                       SQL              -                -                        tombstone is nobody's friend (A6)
InMemory store mirrors SQL                  swift test       each method      each hint                failNext for 4 operations
DeepLink .friend, both forms                swift test       parse, build     bad token, long hint     40-char cap (R15)
GroupsSession.refresh + saved set           swift test       two friends      store throws             first load silent, removed id (R11, R25)
wheel face source                           swift test       friends          -                        plan members win (R10)
link cache per account                      swift test       -                -                        second account sees nothing (R23)
Sheet, QR, Accept, Remove, arrival          UI test          each             each recipient state     SE + AX3 sizes
Landing + AASA                              manual, device   installed / not  host down                script and bidi hint (A8)
```
The test for 2am on a Friday: the SQL test that a friend who is not a recipient reads zero of the other's plans and that `hidden_from` still answers "no such plan". The hostile test: accept a link, get removed, reset nothing, accept again, expect "expired". The chaos test: accept and delete_account in both commit orders. Pyramid is right: SQL and core tests carry the rules, UI tests carry states. Flakiness: the 2-second row highlight and the 1.5-second "Copied" label need the injected clock or `-FriendCalToastSeconds`-style control; expiry tests need `clock_timestamp` control or rows written with past dates. No LLM or prompt changes.

#### Section 7: Performance
`friendships` needs an index usable from either side of the pair; the canonical one-row-per-pair key covers one direction, so `my_friends()` and `friendcal_is_friend` need a second index or a both-columns lookup (Eng phase). The `users` read policy now runs the friend check per row read; with the helper marked `stable` and reads limited to a handful of ids this is small, and it must not turn the Invites or Home name lookups into a per-row function storm (Eng phase to check the plan). No caching, jobs or pool pressure. Slowest new path: accept (two locks, three reads, two writes), well under 100 ms [estimated].

#### Section 8: Observability
Day-one visibility is the saved query in R29. Failures are visible to the user through mapped sentences, and to nobody else: there is no server log of accept answers. At this scale that is acceptable; the first sign of a problem will be a friend saying "your link says expired", and the query plus `friend_links.expires_at` answers it. Runbook additions (README): apply order with `friends.sql`, how to read the counters, and "a link reads expired" triage (expired, reset, removed, deleted). The missing push forwarder is the real observability hole: `push_outbox` rows with `sent_at is null` pile up unseen today.

#### Section 9: Deployment and rollout
```
1. Apply SQL (schema_additions, users_auth, social, friends) ─▶ self-checks print "verified"
2. Ship app build with T1-T3, T5 (sheet reachable from the debug sheet only)
3. Domain + host + AASA live ─▶ verify on a device: installed, not installed
4. Public TestFlight link approved
5. Ship build with T4 + T6 (entry points on, https links)
Rollback: step 5 ─▶ previous build; step 3 ─▶ repoint DNS; step 1 ─▶ leave applied (additive)
```
Old app plus new SQL is safe: nothing the old app calls changes meaning, except that `send_poke` now also accepts friends. New app plus old SQL fails at the first friend call with a missing-function error, so SQL goes first. Post-deploy check: mint a link on one account, accept on another, see both rosters, remove, see "expired". The live project has drifted from the repo before (learning `live-supabase-had-allow-all-policies`), so step 1 ends with a `pg_policies` diff.

#### Section 10: Long-term trajectory
Reversibility 4/5: tables and functions are additive, copy is editable, and the only hard-to-undo parts are links already in people's message threads and the domain. Debt: crews and statuses stay on the device while friends move to the server, so Groups is half live; the plan says so (R8) and the deferred statuses item closes it. Path dependency is good: `friendcal_is_friend` is the gate statuses and crews will reuse. Phase 2 is statuses and the push forwarder; phase 3 is crews as plan recipients (`TODOS.md:174`) and, if UC3 is approved now or later, connection through plans. The cherry-picks were right with one reversal: block-on-remove (R27) turned out to be needed, as both voices said.

#### Section 11: Design and UX
The design review already ran (7/10). CEO-level checks only. Hierarchy on the sheet is right: link, then Share, then QR. The recipient flow has one decision per screen. Gaps this review adds for the Design phase: the Remove action and its dialog on `FriendCard` (R27), the roster's failed-refresh state (R8), the Moments line when several friends join at once, the accept line and share copy if UC1 and UC2 are approved, and the friend variant of the sign-in pill (R5).
```
[Groups +]/[wheel]/[seat] ─▶ Add a friend sheet ─▶ Share / Copy / QR sheet
                                   └─ Reset link ─▶ confirm ─▶ "New link ready"
link ─▶ (not installed: landing ─▶ TestFlight ─▶ tap link again) ─▶ (sign in) ─▶ Accept
Accept ─▶ Connect ─▶ Groups: row highlight + Moments + FriendCard
       ├▶ Not now ─▶ back
       └▶ expired / own / already ─▶ one action each
FriendCard ─▶ Remove friend ─▶ confirm ─▶ row leaves
```

#### NOT in scope (CEO)
Deferred, with a TODOS.md entry at approval: push forwarder and the app-side `friend_joined` routing (A11, R19); statuses on the server (E8); join count on the sheet (E4); a general block list beyond remove (E10); custom VoiceOver announcements (E11). Rejected: sender approval of each request (S1, contradicts 1B). Noted, no TODO: browser or non-iOS participation; discovering which contacts already use FriendCal (needs an identity the app does not collect).

#### Failure modes registry
| Codepath | Failure | Rescued | Test | User sees | Logged |
|---|---|---|---|---|---|
| Sheet open, no cache, offline | no link | Y | UI (failNext) | Error + Retry | N |
| Accept on dead token | expired | Y | SQL + UI | Expired state | N |
| Accept racing reset/delete | wrong pair state | Y | SQL two-session | Connected or expired, per order | N |
| Removed person re-accepts | reconnects | Y (R27) | SQL | Expired | row in `friend_removals` |
| Groups refresh fails | empty roster | Y (R8 addendum) | swift test | Last roster + quiet retry | N |
| `friend_joined` push | never delivered | N | SQL (row written) | Nothing while away; Moments on next open | row unsent in `push_outbox` |
| Landing host down | dead link for new people | N | manual | Browser error | N |
| AASA not propagated | link opens the page for installed users | N | manual | "Get FriendCal" page; app not opened | N |
No row is unrescued, untested and silent at once. Two rows are unrescued and visible (push, host); both are named in the gate.

#### Dream state delta
After this plan: real friends from the server, a link and QR that connect two people in one tap each, removal that sticks, pokes allowed between friends. Still short of the ideal: nothing arrives while the app is closed, a friend's row shows a name and Busy only, crews live on one phone, and the fastest way to bring a group in is still one link per person.

```
+====================================================================+
|            MEGA PLAN REVIEW — COMPLETION SUMMARY                   |
+====================================================================+
| Mode selected        | SELECTIVE EXPANSION                         |
| System Audit         | Groups roster and statuses are fixtures;    |
|                      | no push forwarder exists; no domain setup   |
| Step 0               | 11 premises (3 false, 2 unverified);        |
|                      | 3 spec reviews (5, 6, 6 of 10)              |
| Section 1  (Arch)    | 2 issues found                              |
| Section 2  (Errors)  | 16 error paths mapped, 1 GAP (closed)       |
| Section 3  (Security)| 9 threats, 0 High unmitigated               |
| Section 4  (Data/UX) | 10 edge cases mapped, 1 partial             |
| Section 5  (Quality) | 1 issue found                               |
| Section 6  (Tests)   | Diagram produced, 0 gaps                    |
| Section 7  (Perf)    | 2 issues found (Eng phase)                  |
| Section 8  (Observ)  | 1 gap found (push backlog unseen)           |
| Section 9  (Deploy)  | 2 risks flagged                             |
| Section 10 (Future)  | Reversibility: 4/5, debt items: 2           |
| Section 11 (Design)  | 5 issues for the Design phase               |
+--------------------------------------------------------------------+
| NOT in scope         | written (8 items)                           |
| What already exists  | written (0B)                                |
| Dream state delta    | written                                     |
| Error/rescue registry| 16 rows, 0 CRITICAL GAPS                    |
| Failure modes        | 8 total, 0 CRITICAL GAPS                    |
| TODOS.md updates     | 5 items proposed (written at approval)      |
| Scope proposals      | 16 proposed, 11 accepted, 4 deferred, 1 cut |
| CEO plan             | written                                     |
| Outside voice        | codex completed (8 findings)                |
| Lake Score           | N/A (no coverage-scored questions asked)    |
| Diagrams produced    | 6 (architecture, link and pair state,       |
|                      | data flow, ordering schedule, deploy, flow) |
| Stale diagrams found | 0 (GroupsView.swift:9 header stays true)    |
| Unresolved decisions | 5 user challenges, 2 taste, 1 question      |
| Reality rows         | 8/8 rows (PLAN_REALITY), 2 unverified       |
+====================================================================+
```
Held for the final gate: UC1 copy says only what ships; UC2 "ask to connect"; UC3 connect through plans; UC4 short code; UC5 7-day expiry; taste d3 (plan links in T4) and d4 (push forwarder as its own plan next); question: is `friendcal.app` owned.

#### Outside this plan (found while reviewing)
- Security, latent: `busy_blocks.visibility` is readable by every signed-in client (`rls.sql:379`), while the sanitized view leaves it out (`rls.sql:266`). A client can tell a `stealth` block from a `public` one, which is the signal the stealth design hides. The server writes only `public` today (`lock_proposal.sql:157`), so nothing leaks until a stealth block exists. Static read, not exploited. Fix: drop `visibility` from the column grant.
- Product: no push is delivered at all. `social.sql:33` names an Edge Function that is not in the repo and the live project has none. Pokes shipped in 0.4.0.0 queue rows that are never sent.
- Honesty: Groups shows "Status shared" for a status that stays on the device (`GroupsSession.swift:5`).
- Stale TODO: "Poke's build" (`TODOS.md:219`) describes work that mostly shipped.

<!-- AUTONOMOUS DECISION LOG -->
## Decision Audit Trail

| # | Phase | Decision | Classification | Principle | Rationale | Rejected |
|---|-------|----------|----------------|-----------|-----------|----------|
| 1 | CEO | Mode: SELECTIVE EXPANSION | Mechanical | override | Added capability on shipped code | Reduction (22 files, but three shippable slices) |
| 2 | CEO | A1 server-backed Groups roster | Mechanical | P1 | Roster is fixtures; friend would never appear | Leave Groups on fixtures |
| 3 | CEO | A2 store seam | Mechanical | P1 | Views need something to call | - |
| 4 | CEO | A3 widen poke gate | Mechanical | P1 | Contract says friends can poke | - |
| 5 | CEO | A4 push kind (server side) | Mechanical | P1 | Constraint rejects the kind | - |
| 6 | CEO | A5 remove a friend | Mechanical | P2 | Undo for an instant link; in blast radius | No removal |
| 7 | CEO | A6 deletion clears friendships | Mechanical | P1 | Tombstone must not be a friend | - |
| 8 | CEO | A7-A10 link contract, landing safety, two link forms, T4 prerequisites | Mechanical | P5 | Explicit rules | - |
| 9 | CEO | Defer push forwarder | Taste (d4) | P2/P3 | New infrastructure; both voices want it sooner | Pull into this plan |
| 10 | CEO | Defer statuses backend, join count, general block | Mechanical | P2 | Outside blast radius or changes approved mockup | Include |
| 11 | CEO | Skip sender approval | Mechanical | user decision 1B | Contradicts the link model | - |
| 12 | CEO | Spec review fixes R1-R26 (40 of 45 issues) | Mechanical | P1/P5 | Each closes a named gap | - |
| 13 | CEO | 0H documents approved | Mechanical | P6 | Both reflect the decisions | Revise again (review cap reached) |
| 14 | CEO | R27 remove sticks, single confirm | Mechanical | P1/P5 | Both voices; simpler than three choices | Three-choice dialog; general block list |
| 15 | CEO | R28 entry points ship with T4 | Mechanical | P1 | Both voices; matches the plan's own P1 on T4 | Installed-only release first |
| 16 | CEO | R29 counters and one measure | Mechanical | P1 | Both voices | No measurement |
| 17 | CEO | R30 two factual corrections | Mechanical | P5 | Verified in code | - |
| 18 | CEO | R31 consolidate before building | Mechanical | P5 | Patch pile risk | - |
| 19 | CEO | Keep outbox row, wheel fallback, two-session tests | Mechanical | P1 | Small, each closes a stated outcome | Claude voice #8 cuts |
| 20 | CEO | d3 plan links in T4: include | Taste | P2/P4 | One AASA, one landing | Defer (spec reviewer) |
| 21 | CEO | Roster failed-refresh state added to R8 | Mechanical | P1 | Only error-map gap | Empty list on failure |
| 22 | CEO | UC1-UC5 not decided | User Challenge | - | Both voices want to change the user's decisions | Auto-deciding |
| 23 | Design | DS1, DS2 accept and mutation states | Mechanical | P5 | Missing states; both voices | Leave to the implementer |
| 24 | Design | DS3 no auto-opened FriendCard | Mechanical | P5 | The plan's own fallback; both voices | Auto-open |
| 25 | Design | DS4 arrival held until Groups is visible, tab dot | Mechanical | P1 | Moment was lost off screen | Fire on any refresh |
| 26 | Design | DS5 neutral dead-link line | Mechanical | P5 | R27 made the old line false; both voices | Keep "Ask Sam for a new one" |
| 27 | Design | DS6 Remove placement and dialog text | Mechanical | P5 | Near-irreversible action must say so | Row beside Poke |
| 28 | Design | DS8 22-character token, display form | Mechanical | P5 | Row could not meet its own spec | Truncate; 22-64 range |
| 29 | Design | DS9 landing variants; dead-link risk accepted | Taste | P3 | Live check needs a public endpoint | Anonymous preview call |
| 30 | Design | DS10, DS13, DS14, DS16, DS19-DS21 | Mechanical | P5 | Unspecified details | - |
| 31 | Design | Keep link row above Share; keep title cap | Mechanical | user decision | Approved mockup and earlier review | Codex #5, #6 |
| 32 | Design | UC6, UC7, d5 not decided | User Challenge / Taste | - | Reverse or reword the user's decisions | Auto-deciding |
| 33 | DX | Phase ended at the DX skill's applicability gate | Mechanical | P3 | Trigger was "card shell"; no developer-facing surface | Full DX review of a consumer app |
| 34 | Eng | EN1 link router above sign-in | Mechanical | P1 | Pending link is never stored; both voices | Patch the replay in place |
| 35 | Eng | EN2 poke re-check after the lock | Mechanical | P1 | Both voices | Leave the order |
| 36 | Eng | EN3 token from gen_random_uuid, floor 120 bits | Taste | P5 | No extension dependency; Claude wanted 128 bits via pgcrypto | Qualify pgcrypto in the extensions schema |
| 37 | Eng | EN4 shape A: objects in schema_additions, edits in owning files | Mechanical | P5 | Repo's stated order; shape B cannot avoid the delete_account change | Self-contained friends.sql |
| 38 | Eng | EN5, EN6, EN7 removal table, function access, test fix | Mechanical | P1 | Unspecified or wrong | - |
| 39 | Eng | EN8 Accept waits for an open sheet to close | Taste | P5 | Never discards typing | Dismiss sheets and present |
| 40 | Eng | EN9 no name step; TODO | Mechanical | P3 | New auth step is outside this plan | Add a profile gate now |
| 41 | Eng | EN10-EN17, EN19 | Mechanical | P1 | Each closes a named failure | - |
| 42 | Eng | EN18 cap of 50 accepts per token | Mechanical | P1 | One column bounds a leaked link | No cap; per-caller rate limits |
| 43 | Eng | EN20 three PRs | Mechanical | P3 | Slices ship separately; T4 blocked on a domain | One PR |
| 44 | Eng | TODOS.md written at approval, not now | Mechanical | P6 | The plan is not approved yet | Auto-write during the phase |

### Phase 2: Design review (re-run on the amended plan)

#### Step 0
- Initial rating of the amended plan: 5/10. The sender sheet is specified to the point size; the recipient path, the moment after Connect, the sender's arrival moment and every mutation in flight are not. A 10 here means one merged spec where every screen has its container, its in-flight and failure states, a single decided landing after success, and copy that describes what ships.
- DESIGN.md exists; everything is calibrated against it. Mockups: the two approved today (sheet, accept) stay the visual reference; none were regenerated because no accepted change alters those two layouts.
- Existing patterns to reuse: sheet with its own toast (Availability sheet in DESIGN.md), outlined pill for the quiet action, `FriendAvatar` initials fallback, the `quiet` presence row, the Pokes tab badge.

#### Step 0.5: two independent voices (snapshot 50bbc630)
Claude subagent: completed, 22 findings (3 critical, 10 high, 9 medium). Codex (outside): completed, 10 findings (6 high, 4 medium), verdict FINDINGS.
```
DESIGN OUTSIDE VOICES — LITMUS SCORECARD
  Check                                    Claude     Codex   Consensus
  1. Brand unmistakable in first screen?   not asked  YES     N/A (one voice)
  2. One strong visual anchor?             not asked  YES     N/A
  3. Scannable by headlines only?          not asked  YES     N/A
  4. Each section has one job?             not asked  NO      N/A (expiry row does three jobs)
  5. Cards actually necessary?             not asked  NO      N/A (flat layout is right)
  6. Motion improves hierarchy?            not asked  NO      N/A (none specified; fine)
  7. Premium without decorative shadows?   not asked  YES     N/A
  Hard rejections triggered:               -          2 (not from the fixed list: false consent copy; coral button contrast)
```
The native voice was given the standard completeness brief, which has no litmus questions, so the scorecard is single-voice. Findings both voices raised: false consent and "ask to connect" copy; no in-flight states for accept, reset and remove; the after-Connect landing left to the implementer; seat cards promising a crew they do not fill; the removed person told to "ask for a new one"; the link row that cannot fit; the missing short-code screen.

#### Pass 1: Information architecture, 6 → 8
- Seat cards as an entry point (both voices): a seat inside a crew says "add someone to this crew"; the joiner lands elsewhere. This reverses your 1A decision, so it is USER CHALLENGE UC6, not decided here.
- Groups header control: accepted DS13.
- After Connect (both voices): the plan hedges between an auto-opened card and the highlighted row. Decided DS3: take the plan's own fallback.
- Codex would put Share above the link row. Not taken: the approved mockup (5/5 on the board) has the link first and one coral control; that is your call and it stands.
```
Add a friend sheet           Accept (full-screen cover)        Groups after connect
1 title + Done               1 wordmark                         1 Moments: "You and Sam are connected"
2 what the link does         2 Sam + You, joined                2 Sam's row, highlighted
3 the link + Copy            3 headline                         3 tab dot until seen (sender side)
4 expiry + Reset             4 what Sam will see
5 Share (coral)              5 Connect (coral)
6 Show QR code               6 Not now
```

#### Pass 2: Interaction states, 5 → 8
Added by DS1, DS2, DS4, DS9, DS14 (accepted block below). The state table gains these rows:

| Surface | In flight | Failure | Notes |
|---|---|---|---|
| Accept: checking the link | Skeleton for names, "Checking link" for VoiceOver | Inline error + Retry; link kept | Not "redeeming"; nothing is redeemed yet |
| Accept: Connect tapped | Button shows progress and "Connecting", disabled; Not now disabled | Inline error under the button + Retry; a dead link swaps the screen to the dead-link state | Double tap cannot fire twice |
| Sheet: Reset / Make a new link | Reset shows progress; Copy, Share and QR disabled until the new link is shown | Inline error + Retry; old link stays | Toast shows inside the sheet |
| FriendCard: Remove | Dialog closes, card dismisses, row dims | Row returns; toast with the mapped sentence | Success: row leaves, toast "Removed Sam" |
| Groups roster | Last roster stays; no spinner on refresh | R32 | New friend with no status shows the existing quiet row |
| Sender arrival | - | - | Held until Groups is on screen; tab dot until then; "Jess and 2 others" when several |
| QR | Mirrors the sheet's link state | Same error as the sheet | Dark on white with a quiet zone, screen brightness raised while shown |
| Landing (T4) | - | Dead links cannot be detected on a static page (accepted risk, DS9) | iPhone, in-app browser, not-iPhone and no-name variants |

#### Pass 3: Journey, 4 → 7
| Step | Recipient does | Feels | Plan specifies |
|---|---|---|---|
| 1 | Gets "Sam wants to connect" in a message | Curious; trusts Sam | Share text (copy pending UC1) |
| 2 | Taps; no app: landing page | "What is this?" | One screen, one button (T4) |
| 3 | Installs from TestFlight, opens | Effort; patience running out | Nothing carries the invite across the install (pending UC4) |
| 4 | Signs in, names themselves | Slight friction | Existing gate; pill names Sam (DS21) |
| 5 | Sees Accept, reads what Sam will see | Deciding | One line of consent (copy pending UC1) |
| 6 | Taps Connect | Small win | In-flight state, then Groups with Sam's row lit (DS1, DS3) |
| 7 | Looks for what to do next | "Now what?" | Poke exists and may not be delivered; no plan prompt (pending UC3) |
Five seconds: the accept screen's art and one coral button carry it. Five minutes: step 7 is the weak point; a new friendship ends on a roster row. Five years: the graph is worth having only if plans grow from it, which is UC3's argument. The score stays at 7 because steps 3 and 7 wait on your decisions.

#### Pass 4: AI slop risk, 9 → 9
Classifier: Operate for the sheet, QR and Accept; Persuade for the landing. No hard-rejection pattern from the fixed list applies: flat sheet, no card grid, one coral control, art without text. Litmus (mine): brand unmistakable YES (wordmark, Cabinet, cream and coral); one anchor YES; scannable YES; one job per section NO for the expiry row (date, disclosure and Reset on one line; kept, it is the approved mockup); cards necessary NO and none are used; motion NO and none is needed; premium without shadows YES. Landing as Persuade: one primary action ("Get FriendCal"), no invented proof, the risk reversal is honest ("free on TestFlight" only if true at the time), and the page is `noindex` because it is a per-person invite. No issues beyond those.

#### Pass 5: Design system alignment, 8 → 8
New components fit the vocabulary: link row (hairline, mono, one 44pt control), accept screen (wordmark + art + one coral pill), tab dot (same as the Pokes badge), Remove as a text control in `error-text`. "Teal" in the plan means `accent-hover` for text (D25); stated in DS13. One issue outside this plan, raised by Codex and confirmed by arithmetic: white on coral `#FF4E2E` is about 3.3:1, under AA for 17pt semibold button text. Every coral button in the app has it; it is listed under "Outside this plan" and not changed here.

#### Pass 6: Responsive and accessibility, 6 → 7
- The link row could not meet its own spec (mono, two lines, never ellipsized, up to 95 characters). Fixed by DS8.
- Codex notes the title cap at xxxLarge departs from full scaling. Not changed: you set it in the first review and the sheet scrolls.
- Focus: each sheet returns focus to its trigger on dismiss (system behavior, stated in DS16). The QR has a text alternative: the same selectable link beneath it.
- Announcements: a VoiceOver user gets no confirmation of copy, reset or arrival, because all three are transient visuals. Both voices say add them. You deferred this in the first review (6B), so it is USER CHALLENGE UC7. The pass stays at 7 until then.

#### Pass 7: Unresolved design decisions
| Decision needed | If deferred |
|---|---|
| UC1 share message and accept line say only what ships | People consent to "status" and are promised "when you're both free"; neither exists |
| UC2 "ask to connect" | Senders think they approve each person |
| UC4 short code | T4 has a required element with no screen |
| UC5 7-day expiry | "Link expired" becomes what a returning sender normally sees |
| UC6 seat cards as an entry point | A crew seat implies membership it does not grant |
| UC7 three VoiceOver announcements | Copy, reset and arrival are silent for VoiceOver users |
| d5 wording pack: "Share link" for "Share invite"; "Sam wants to connect" for "Sam invited you to connect"; "You and Jess are connected" for "Jess joined"; one neutral dead-link line | "Invite" keeps meaning two things; "joined" is false for existing users; a removed person is told to ask for a link that will never work |
Resolved in this pass: 22 (DS1-DS22 below). Deferred: 0 new.

<!-- autoplan-accepted:design -->
- DS1 Accept screen container and states. It is a full-screen cover presented by the shell over whatever is on screen; any open sheet stays underneath and is still there on dismiss. States: checking the link (skeleton), ready, Connect in flight (button shows progress and "Connecting", both buttons disabled), failed (inline error under the button with Retry, link kept), and the three non-connect answers shown on the same screen with one action each. Layout follows the approved accept mockup (wordmark, two avatars joined by an arc, headline, one consent line, coral Connect, quiet Not now); a person without a photo gets the existing `FriendAvatar` initials. Test: UI test per state through `-FriendCalFriendLink` and `-FriendCalFailNext`.
- DS2 Mutations in flight. Reset and "Make a new link" show progress on the control and disable Copy, Share and Show QR code until the new link is on screen; on failure the old link stays with an inline error and Retry. Remove closes the dialog, dismisses the card and dims the row; on success the row leaves with a toast "Removed Sam"; on failure the row returns with the mapped sentence. Toasts raised from the sheet show inside the sheet, as the Availability sheet does. Test: UI tests with `-FriendCalStoreLatency` and `-FriendCalFailNext`.
- DS3 After Connect lands on Groups with Sam's row highlighted for 2 seconds, the Moments line and the success haptic. The FriendCard does not open by itself; this is the fallback the plan already names. Under Reduce Motion the highlight is a color change with no animation.
- DS4 The sender's arrival. A new friend is held as "new" until Groups is on screen; until then the Groups tab shows the same dot the Pokes tab uses. Then the Moments line, haptic and highlight play once. Several at once read "Jess and 2 others" and each row highlights. With no push delivery, a sender who is away learns of it on next open; this is a known gap owned by the push forwarder TODO.
- DS5 Dead links. Because a removed person can never use that sender's links again (R27), the dead-link state never tells anyone to ask for a new one. It reads "This link doesn't work anymore." with one button, "OK". The name hint is not shown on this state. (This is also item 4 of wording pack d5; if d5 is declined the neutral line still applies, since the old line is now false for removed people.)
- DS6 Remove. "Remove friend" sits at the bottom of `FriendCard` as a text control in `error-text`, apart from Poke and Tag along. The confirm reads "Remove Sam? Sam won't be able to reconnect with your link. To reconnect later, open Sam's link." with "Remove" (destructive) and "Cancel".
- DS7 If the 7-day expiry stays (UC5), an expired link on the sender's sheet keeps the plan's "Link expired" and "Make a new link" state unchanged.
- DS8 (refines R7) The link. A token is exactly 22 characters of `[A-Za-z0-9_-]`. The row shows `friendcal.app/f/<token>` with no scheme and no `?n=`; Copy, Share and the QR carry the full URL with the name hint. At default sizes that is two lines on an iPhone SE; at accessibility sizes it wraps to as many lines as it needs and is never truncated. VoiceOver reads the row as "Your friend link" with Copy as its action, not the token. Test: UI test on iPhone SE (3rd generation) and at AX3 that the full text is present and nothing is clipped.
- DS9 Landing page states (T4). iPhone Safari: the plan's layout. In-app browsers where the universal link does not fire: a visible "Open in FriendCal" button beside "Get FriendCal". Not an iPhone: "FriendCal is on iPhone for now" and no install button. No usable name hint: "A friend wants to connect on FriendCal". The page is `noindex`. Accepted risk, stated: a static page cannot tell that a link is dead, so someone can install and then meet the dead-link line.
- DS10 First run with a pending friend link: sign in, then the name prompt, then Accept, then Groups. The notification prompt keeps its current trigger (after the first poke) and does not appear in this path.
- DS13 The Groups header control is `person.badge.plus`, labeled "Add a friend" for VoiceOver, 44pt, in `accent-hover`. Every "teal" text or glyph in this plan uses `accent-hover` (D25).
- DS14 QR. Opened from the sheet as a push inside the same sheet at `.large`, with a back control. The code is dark on a white panel with a quiet zone, regardless of tokens; screen brightness is raised while it shows and restored on leaving. The selectable link sits beneath it. Share shares the link, not an image. It mirrors the sheet's loading, error and expired states.
- DS16 Focus returns to the control that opened each sheet when it closes. All new controls are standard buttons and work with Full Keyboard Access and Switch Control without custom handling.
- DS19 A friend with no status on the server shows the existing quiet row. A crew on this device simply lists fewer people when a member is no longer a friend; no empty seat is drawn for them.
- DS20 The pending link survives a cancelled or failed sign-in and app relaunch until it is answered, replaced by a newer link, or dismissed with "Not now".
- DS21 With a pending friend link the sign-in gate's pill reads "Sam wants to connect" (hint) or "A friend wants to connect", and the button reads "Continue". The plan-invite wording ("You were invited to", "Continue to invite") is used only for plan links.
<!-- /autoplan-accepted:design -->

#### NOT in scope (design)
Share above the link row (Codex; the approved mockup stands). Full scaling of the sheet title past xxxLarge (your earlier decision). A live dead-link check on the landing page (needs a public endpoint; risk accepted in DS9). Coral button contrast (system-wide, listed below). Regenerated mockups (no layout changed).

#### What already exists (design)
DESIGN.md tokens and the D27 type table; outlined pill; sheet-local toast; `FriendAvatar`; the quiet presence row; the Pokes tab badge; `PressableStyle`; `.sensoryFeedback`; the approved sheet and accept mockups.

```
+====================================================================+
|         DESIGN PLAN REVIEW — COMPLETION SUMMARY (autoplan re-run)  |
+====================================================================+
| System Audit         | DESIGN.md present; 5 screens + landing      |
| Step 0               | 5/10 on the amended plan; all 7 passes      |
| Pass 1  (Info Arch)  | 6/10 → 8/10 after fixes                     |
| Pass 2  (States)     | 5/10 → 8/10 after fixes                     |
| Pass 3  (Journey)    | 4/10 → 7/10 after fixes                     |
| Pass 4  (AI Slop)    | 9/10 → 9/10                                 |
| Pass 5  (Design Sys) | 8/10 → 8/10                                 |
| Pass 6  (Responsive) | 6/10 → 7/10 after fixes                     |
| Pass 7  (Decisions)  | 16 resolved, 7 held for the gate            |
+--------------------------------------------------------------------+
| NOT in scope         | written (5 items)                           |
| What already exists  | written                                     |
| TODOS.md updates     | 1 item proposed (coral button contrast)     |
| Approved Mockups     | 0 generated, 2 carried from today           |
| Decisions made       | 16 added to plan (DS1-DS21)                 |
| Decisions deferred   | 7 (UC1, UC2, UC4, UC5, UC6, UC7, d5)        |
| Overall design score | 4/10 → 7/10                                 |
+====================================================================+
```
Journey and accessibility stay at 7 because they wait on UC3, UC4 and UC7.

### Phase 2.5: DX review (entered, not applicable)
The scope tool turned this phase on because the word "shell" appears three times in the plan. All three are "card shell", a layout term. The DX skill's own applicability gate asks whether the plan has a developer-facing product surface (an API, CLI, SDK, library, platform, docs product or agent skill that other developers install or build on). It has none: FriendCal is a consumer iPhone app and its only developer is its owner. The gate's instruction for that case is to stop, so no persona, benchmark, scorecard or voices were produced, and none are claimed. The developer-facing details this plan does touch (launch arguments, SQL apply order, error hints, the README query) are covered by the CEO items A2, R2, R14, R17 and R29 and are reviewed again in the Eng phase.

<!-- autoplan-accepted:dx -->
None: the plan has no developer-facing product surface; the DX skill's applicability gate ended the phase before any review, so nothing was accepted or changed.
<!-- /autoplan-accepted:dx -->

### Phase 3: Eng review (on the amended plan, snapshot 5de4378e)

#### Step 0: Scope challenge
What already solves each sub-problem is the 0B table in Phase 1; the Eng read added four facts from code:

| # | Finding | Evidence |
|---|---|---|
| S1 | [CRITICAL] (confidence: 9/10) `app/FriendCal/FriendCalApp.swift:118` — nothing ever writes the pending link. The key `FriendCalPendingLink` is read at `:85` and `:118` and removed at `:121`; no file sets it, and `onOpenURL` is attached to `AppTabView` (`AppTabView.swift:77`), which only exists when signed in. A link opened while signed out is dropped today, for plan links too. The replay also calls `try? await store.join(link.proposalID)` and clears the key even when the join fails. | `grep -rn PendingLink app/` returns three lines, all in `FriendCalApp.swift` |
| S2 | [INFORMATIONAL] (confidence: 9/10) `app/Package.swift:11` — `GroupsSession` and `ProposalSession` live under `Views/`, which the core package excludes, so the "core test of `GroupsSession`" promised in A1, R11, R25 and R32 cannot run in the `swift test` lane. | `exclude: [... "Views" ...]`; `ProposalSessionTests.swift:1` says it runs app-hosted |
| S3 | [INFORMATIONAL] (confidence: 8/10) `supabase/schema.sql:4` — `gen_random_bytes` is pgcrypto; on Supabase pgcrypto lives in the `extensions` schema while every definer function here sets `search_path = public` (`social.sql:164`). No SQL in the repo calls it today; `gen_random_uuid()` is core and is what the repo uses. | `grep -n gen_random supabase/*.sql` shows only `gen_random_uuid` |
| S4 | [INFORMATIONAL] (confidence: 9/10) `supabase/social.sql:185` — `send_poke` checks who may poke and then takes the user locks at `:193`. With friendship added to the check, a removal that commits between the two still lets the poke and its push through. | lines quoted in Phase 1 |

Complexity: about 24 changed or new files [estimated] and no new service. That is over the 8-file line; under the /autoplan rule the scope is not reduced. The arrangement question is answered by the design-twice comparison in Section 1. Search check: no search tool in this session; in-distribution only. [Layer 1] universal links through an `apple-app-site-association` file and `onOpenURL`/`onContinueUserActivity` are the platform's built-in path; nothing custom is proposed. Distribution: the only new artifact is a three-file static site (page, AASA, share image); its host and deploy step are T4 prerequisites and are not chosen yet.

REALITY: premise-table finding eng read added one false premise (pending link is never stored), total false 4 of 12, unverified=2 app/FriendCal/FriendCalApp.swift:118
REALITY: already-done pass re-checked after fetch, no friend work on origin/main 95093af
REALITY: surface-check finding launch arguments named by the plan do not exist yet and are listed for CLAUDE.md; `-FriendCalFailNext` exists app/FriendCal/FriendCalApp.swift:47
REALITY: binding-decisions pass none overruled; UC1-UC7 keep the user's decisions until the gate docs/designs/friendcal-add-friend.md:8
REALITY: numbers pass every effort figure is [estimated]; the one measured figure is the white-on-coral ratio 3.3:1 [measured: WCAG formula on #FF4E2E] DESIGN.md:104
REALITY: deferred-asks pass no linked issue docs/designs/friendcal-add-friend.md:63
REALITY: pr-count finding three PRs (SQL, app, web plus entry points) against the default of one; each extra PR costs one more run of the three test lanes (about 10s core, 20s SQL, plus the iOS lane) and a second review CLAUDE.md:9
REALITY: transaction-semantics pass no driver or pool change; each new function is one transaction and locks in the existing order supabase/lock_proposal.sql:32

#### Step 0.5: two independent voices
Claude subagent: completed, 5 high, 9 medium, 7 low. Codex (outside): completed, 11 findings (5 high, 6 medium), verdict FINDINGS.
```
ENG DUAL VOICES — CONSENSUS TABLE
  Dimension                           Claude            Codex             Consensus
  1. Architecture sound?              Yes, with fixes   Yes, with fixes   CONFIRMED (fixes EN1, EN4, EN5)
  2. Test coverage sufficient?        No                No                CONFIRMED gap (EN7, EN10, EN13)
  3. Perf risks + budget/bench named? Minor, no bench   Not raised        CONFIRMED low; no hot path
  4. Security threats covered?        No (3 gaps)       No (token)        CONFIRMED gap (EN3, EN6, EN16)
  5. Error paths handled?             No                No                CONFIRMED gap (EN11, EN12, EN15)
  6. Deployment risk manageable?      Yes, with fixes   Yes, with fixes   CONFIRMED (EN4, EN10)
```
Both raised: the pending link (S1), the poke check before the lock (S4), the token and pgcrypto (S3), the under-specified removal record, and tests that cannot run where the plan puts them (S2). Claude alone: function privileges, the cover over an open sheet, two clocks for expiry, referrer leakage on the landing page. Codex alone: the missing name step on the real store, the upgrade lane never seeing an old `push_outbox`, stale refreshes overwriting newer state, a reset whose response is lost. One disagreement between them, on the token: Claude says a UUID is too few bits for the 128-bit floor; Codex says qualify pgcrypto. Decided in EN3.

#### Section 1: Architecture
```
 app (SwiftUI)                                   FriendCalCore (swift test lane)
 ┌─ RootGateView ── LinkRouter (NEW, above auth) ── DeepLink (+ .friend) ── ShareText (+ friendLink)
 │      │ pending link, per kind, generation      FriendRoster (NEW: diff, saved set, wheel source)
 │      ├─ AuthGateView (pill: friend variant)    ProposalStore protocol (+ 6 methods)
 │      └─ AppTabView ── AcceptFriendView (NEW)     ├─ InMemoryProposalStore (friendships, links, removals)
 │             ├─ GroupsView ── AddFriendSheet (NEW) └─ SupabaseProposalStore ──────────────┐
 │             │      └─ QR (NEW)   FriendCard (+ Remove)                                    │ rpc
 │             │   GroupsSession (+ store, refresh generation)                               ▼
 │             └─ HomeView ── FriendsWheel (faces from FriendRoster when no plan members)  Supabase
 └─────────────────────────────────────────────────────────────────────────────────────────────
 supabase, apply order:
   schema_additions.sql  + friendships, friend_links, friend_removals (RLS on, no grants), friendcal_is_friend()
   lock_proposal.sql       (friendcal_lock_users, unchanged)
   rls.sql               + three tables in the RLS-on guard list
   users_auth.sql        + one policy arm; delete_account(): caller joins the lock set, clears friend rows
   ...  social.sql       + send_poke re-checks after the lock; push_outbox kind list (in place)
   friends.sql (NEW, last) friend_link, reset_friend_link, preview_friend_link, accept_friend_link,
                           remove_friend, my_friends, self-check
 friendcal.app (T4)      /.well-known/apple-app-site-association, /f/* page, share image
```
Two shapes, as the method asks for a new boundary. Shape A (above): objects are created in `schema_additions.sql`, which the harness documents as the file "every policy, view and function after it may assume" (`scripts/test-sql.sh:59`), and each existing object is changed in the file that owns it. Shape B: one self-contained `friends.sql` applied last, adding a second permissive policy on `users` and a deletion trigger like `social.sql:423`, leaving `users_auth.sql` and `rls.sql` untouched. B hides more behind one file, and it fails on one point Codex verified: a trigger cleans up but does not serialize, because `delete_account()` only locks people who have holds (`users_auth.sql:168`), so an accept could insert a friendship beside an uncommitted tombstone. `delete_account()` has to change either way, and the RLS-on check in `rls.sql` runs before `friends.sql` would have created anything. Pick: A. Red flags screened: hand-synced list (the `rls.sql` table list and the `push_outbox` kind list each stay single, in their owning file; `friends.sql` re-checks its own tables the way `social.sql:444` does); two ways to do one task (the link router replaces the replay in `FriendCalApp.swift`, it does not sit beside it); split ownership (the roster has one owner, `FriendRoster`, with `GroupsSession` and the wheel reading it); information leakage (the "expired" union is decided in SQL and mirrored once in the in-memory store). No other flag applies.

Production failure per new path: accept racing deletion (handled, EN4); a reset whose reply is lost (EN12); a refresh that started before a remove finishing after it (EN11); a link tapped while a sheet is open (EN8); host down or AASA not propagated (not handled in code; manual check and rollback in Section 9 of Phase 1).

Findings:
- [CRITICAL] (confidence: 9/10) `app/FriendCal/FriendCalApp.swift:118` — S1 above. Disposition: accepted, EN1.
- [CRITICAL] (confidence: 8/10) `supabase/users_auth.sql:168` — "select coalesce(array_agg(distinct s.user_id), '{}') into v_affected from availability_slots s where s.source_proposal_id = any (v_cancelled) or s.user_id = v_uid"; a caller with no holds takes no user lock, so accept and delete do not serialize. Disposition: accepted, EN4 (keeps R12's "caller joins the lock set").
- [INFORMATIONAL] (confidence: 9/10) `supabase/social.sql:185` — S4. Disposition: accepted, EN2.
- [INFORMATIONAL] (confidence: 8/10) `supabase/social.sql:98` — the kind list would live in two files under R17. Disposition: accepted, EN4.
- [INFORMATIONAL] (confidence: 7/10) plan item R27 — the removal record has no table, no access rules and no deletion cleanup, and an idempotent remove could pre-block a stranger. Disposition: accepted, EN5.
- [INFORMATIONAL] (confidence: 7/10) plan item DS1 — a full-screen cover presented by the shell while a child sheet is up is deferred or dropped by the system. Disposition: accepted, EN8.
- [INFORMATIONAL] (confidence: 8/10) `app/FriendCal/Views/Auth/AuthGateView.swift:77` — the name field shows only on the in-memory store; on the real store a missing Apple name becomes "Friend" (`SupabaseProposalStore.swift:161`), so DS10's "name prompt" step does not exist there. Disposition: accepted as a correction, EN9; the missing step is a TODO.

#### Section 2: Code quality
- [INFORMATIONAL] (confidence: 9/10) `app/Package.swift:11` — S2. The roster rules belong in a core type so the fast lane covers them. Disposition: accepted, EN13.
- [INFORMATIONAL] (confidence: 8/10) `supabase/schema.sql:4` — S3. Disposition: accepted, EN3.
- [INFORMATIONAL] (confidence: 7/10) plan items A2, R14 — no rule for `revoke`/`grant` or `search_path` on about eight new functions; Postgres grants EXECUTE to PUBLIC by default and an `anon`-callable preview would turn a token into a name without sign-in. The repo revokes per function (`social.sql:246`). Disposition: accepted, EN6.
- [INFORMATIONAL] (confidence: 8/10) `supabase/tests/helpers.sql:48` — R2's "reads zero rows" test is wrong for a table with no grants: the read is refused, and `t.rows` raises on that. Disposition: accepted, EN7.
- [INFORMATIONAL] (confidence: 7/10) plan items R8, R32 — nothing orders a refresh against a local accept or remove; an older read can finish last and undo it on screen. Disposition: accepted, EN11.
- [INFORMATIONAL] (confidence: 7/10) plan item DS2 — "the old link stays" after a failed reset is wrong when the reset committed and only the reply was lost. Disposition: accepted, EN12.
- [INFORMATIONAL] (confidence: 6/10) plan sheet states — Medium confidence, verify this is actually an issue: expiry would be judged by the device clock on the sheet and the server clock on accept. Disposition: accepted, EN14.
Shared code: `friendcal_is_friend` has three proposed callers (the `users` policy, `send_poke`, `accept_friend_link`) and one definition. `DeepLink.sanitizedTitle` gains a cap parameter and keeps two callers. No extraction beyond those. No touched file's diagram goes stale except `GroupsView.swift:9` ("Invites are still an honest stub"), which T6 must update.

#### Section 3: Tests
Framework, from CLAUDE.md: `swift test` (core), `scripts/test-sql.sh` (SQL), `xcodebuild test` (app-hosted unit and UI). Existing tests this plan leans on: `DeepLinkTests`, `InMemorySocialStoreTests`, `GroupsLogicTests`, `UserFacingErrorTests`, `GroupsUITests`, `LockedInviteUITests` (the only test that opens a URL), `social_test.sql`, `users_auth_test.sql`, `rls_test.sql`. None covers friends.
```
CODE PATHS                                                    USER FLOWS
[+] supabase/friends.sql                                      [+] Sender
  ├── friend_link()                                             ├── [GAP] [→E2E] open sheet, copy, share
  │   ├── [GAP] mint when none; returns own row as-is           ├── [GAP] reset: confirm, in flight, lost reply
  │   └── [GAP] signed out / deleted caller refused             ├── [GAP] sheet on SE and at AX3, link unclipped
  ├── reset_friend_link()                                       ├── [GAP] QR: shows, mirrors expired/error
  │   └── [GAP] new token, old token dead, friendships kept     └── [GAP] second account never sees first's link
  ├── preview_friend_link(token)                              [+] Recipient
  │   ├── [GAP] valid → inviter id + name                       ├── [GAP] [→E2E] signed in: link → Accept → Connect → Groups
  │   ├── [GAP] dead: unknown, reset, expired, deleted,         ├── [GAP] [→E2E] signed out: link survives sign-in (S1)
  │   │         removed, over cap → one answer                  ├── [GAP] link opened while a sheet is open
  │   └── [GAP] own / already                                   ├── [GAP] double tap Connect; reply lost then retry
  ├── accept_friend_link(token)                                 ├── [GAP] Not now does not return on relaunch
  │   ├── [GAP] one row per pair; double accept; mutual         ├── [GAP] dead / own / already, one action each
  │   ├── [GAP] same dead answers as preview (parity)           └── [GAP] newer link replaces older pending link
  │   ├── [GAP] one push row, 24h expiry, none on repeat      [+] After connecting
  │   ├── [GAP] vs reset, vs delete, vs remove (both orders)    ├── [GAP] row highlight + Moments, no auto-opened card
  │   └── [GAP] cap reached → dead                              ├── [GAP] sender: held until Groups shows; tab dot
  ├── remove_friend(p_user)                                     ├── [GAP] several arrivals read "Jess and 2 others"
  │   ├── [GAP] both directions lose name + poke                ├── [GAP] wheel empty state goes away
  │   ├── [GAP] record only if a row was deleted                └── [GAP] refresh fails: last roster stays
  │   └── [GAP] removed person: dead; remover can reconnect   [+] Remove
  ├── my_friends()                                              ├── [GAP] confirm text, row leaves, toast
  │   └── [GAP] excludes deleted accounts                       └── [GAP] failure: row returns
  └── self-check: RLS on, no grants, anon cannot execute      [+] Existing behavior at risk (REGRESSION)
[+] changed in place                                            ├── [★★★ TESTED] plan link opens the invite — LockedInviteUITests:317
  ├── users policy arm        [GAP] friend reads name;          ├── [★★  TESTED] poke between plan-mates — social_test.sql
  │                                  stranger does not          ├── [★★  TESTED] delete_account outcomes — users_auth_test.sql
  ├── send_poke               [GAP] friends may poke;           └── [GAP] CRITICAL: plan link replay after sign-in still joins
  │                                  re-check after lock                       (the router replaces that code)
  ├── delete_account          [GAP] clears all friend rows
  ├── push_outbox kind        [GAP] old schema with a queued row upgrades
  └── no widening             [GAP] friend reads 0 plans; hidden_from unchanged
[+] app core
  ├── DeepLink .friend        [GAP] both forms; exact host and path; 21/23-char tokens; 40-char hint
  ├── FriendRoster            [GAP] first load silent; new id; removed id; stale generation dropped
  ├── InMemory store          [GAP] each answer, each hint, failNext x4
  └── UserFacingError         [GAP] one sentence per new hint

COVERAGE: 3/52 paths tested (6%)  |  all 3 are existing behavior; every new path is a planned test
QUALITY: ★★★:1 ★★:2 ★:0  |  GAPS: 49 (3 E2E, 0 eval)
```
Legend: ★★★ behavior + edge + error | ★★ happy path | [→E2E] needs a UI test through the real flow.
Regression rule: the plan link replay after sign-in is existing behavior the router rewrites, and it has no test today (it cannot have one: the key is never written). The contract is carried as EN1: opening `friendcal://proposal/<id>` while signed out, then signing in, lands on that invite; a failed join keeps the link. No LLM or prompt files are touched, so no eval suite applies. The test plan is saved at `~/.gstack/projects/rakinne-friendcal/` (path in the Eng summary below).
Dispositions: every [GAP] is accepted as required proof of an accepted behavior (EN-items and the earlier blocks); none is deferred.

#### Section 4: Performance
- [INFORMATIONAL] (confidence: 7/10) `supabase/users_auth.sql:28` — the `users` read policy gains a function call per candidate row. Scale: a roster is 10 to 20 rows and name lookups are by id list; unknown under a table scan. `friendcal_is_friend` is `stable`, and the pair table needs a primary key on the ordered pair plus an index on the second column so either side is an index lookup. Disposition: accepted, EN4.
- [INFORMATIONAL] (confidence: 6/10) plan item R26 — Medium confidence, verify this is actually an issue: every accept of one person's link takes that person's advisory lock, the same key lock, poke and delete use. Scale: at most the cap (50) accepts per token, each a few milliseconds [estimated]. Keep the transaction short with the outbox insert last. No bench is proposed: nothing here is a hot path.
No N+1 (one `my_friends()` call returns names), no cache beyond the per-account link, no unbounded query (`my_friends()` is bounded by the friend count, which the cap and group size keep small).

#### Eng decisions
<!-- autoplan-accepted:eng -->
- EN1 Link router. One owner above sign-in (`LinkRouter`, attached at `RootGateView`) receives every opened URL, parses it once, and stores the pending link on the device. It replaces the replay code at `FriendCalApp.swift:118`. A plan link behaves as the app intends today: opened while signed out it survives sign-in and lands on that invite; a failed join keeps the link for a retry. A friend link opens Accept and calls nothing but preview until Connect is tapped. Each pending link carries a generation number so finishing an older one never clears a newer one. The pending link is cleared when it is answered, on "Not now", on sign-out and on account deletion. `-FriendCalPendingLink none|<url>` pins it for UI tests and is documented in CLAUDE.md with the other launch arguments. Test: UI tests for signed-out plan link, signed-out friend link, failed join keeps the link, and newer-replaces-older; unit test for the generation rule.
- EN2 `send_poke` evaluates "active, and friends or share a plan" after it takes the user locks, not before. Test: SQL test that a removal committed while a poke waits on the lock refuses the poke.
- EN3 (replaces the bit count in A7) Token source. A token is 22 base64url characters made from one `gen_random_uuid()` value, which is core Postgres and needs no extension. That carries 122 random bits; the rule becomes "at least 120 random bits". The 22nd character of a 16-byte value is always a letter, so link detection in Messages cannot cut it short. Test: SQL test for length, alphabet and no repeats over 1,000 mints.
- EN4 (replaces R17's file list) SQL layout. `schema_additions.sql` creates `friendships`, `friend_links` and `friend_removals`, each with row level security on and all client privileges revoked in the same statement group, plus `friendcal_is_friend(p_other uuid)`. `friendships` has one row per pair with the smaller id first, a check that enforces the order, the pair as primary key and an index on the second column. `rls.sql` adds the three tables to its RLS-on list. `users_auth.sql` adds one arm to the read policy and changes `delete_account()`: the caller always joins the user-lock set, and the caller's friendships, link and removal records in both directions are deleted. `social.sql` changes `send_poke` (EN2) and replaces the `push_outbox` kind check in place with a drop-and-add that is safe to re-run. `supabase/friends.sql`, applied after `social.sql` and added after it in `scripts/test-sql.sh:63` and the README order, holds the six client functions and a self-check. No function body or list exists in two files.
- EN5 (completes R27) Removal records. `friend_removals(remover, removed, created_at)`, primary key on the pair, same access rules as the other two tables. `remove_friend` writes a record only when it actually deleted a friendship, so nobody can block a stranger and two people can never hold records against each other. Preview and accept both give the removed person the dead-link answer. The record is cleared when the remover accepts the removed person's link, and by either account's deletion. Pokes already sent between the pair stay in the inbox and show the existing "A friend" name when the name is no longer readable. Test: SQL tests for remove-of-a-non-friend writes nothing, preview and accept parity, deletion clears both directions, and remove then poke through a shared plan is still allowed.
- EN6 Function access. Every new function revokes execute from `public` and `anon`. The six client functions and `friendcal_is_friend` grant execute to `authenticated`; everything else grants to nobody. Every definer function sets `search_path = public`. The `friends.sql` self-check fails if `anon` can execute any of them, if a definer function lacks the setting, or if a client role holds any privilege on the three tables. Test: `t.call` shows `anon` refused on each function.
- EN7 (corrects R2's test) A client read of the three tables is refused with SQLSTATE 42501; the test asserts that through `t.call`, and separately that row level security is on.
- EN8 (corrects DS1) Accept and open sheets. The system will not stack a full-screen cover on an open sheet. A friend link opened while a sheet is up is kept by the router and Accept appears as soon as that sheet closes; nothing the person was typing is dismissed. With no sheet up, Accept appears at once. Test: UI test that opens a friend link with the New plan sheet open, closes the sheet, and sees Accept.
- EN9 (corrects DS10) On the real store there is no name step after sign-in; a person whose Apple ID withheld a name is called "Friend" until they set one in Me. The first-run order is sign in, then Accept, then Groups. Deferred with a TODOS.md entry: ask for a name before the first Connect when the name is still the placeholder.
- EN10 Upgrade proof. The SQL upgrade lane loads the social schema as it is on `origin/main` with one queued poke push before applying this wave, and asserts the row survives and a `friend_joined` row can then be inserted. Applying the whole wave twice stays green.
- EN11 Refresh ordering. Each roster refresh takes a generation number; a local accept or remove bumps it; a refresh that started under an older number is discarded when it returns. The saved-set update and the on-screen roster change together. Test: core test with a paused store that returns the old roster after a remove.
- EN12 (corrects DS2) A failed reset proves nothing about whether the link changed. After any reset failure the sheet re-reads `friendLink()` before Copy, Share and QR are enabled again; if that read also fails they stay disabled with Retry. Test: core test where the store applies the reset and then throws.
- EN13 Where the rules live. Roster diffing, the saved set, the refresh generation and the wheel's face source are a `FriendCalCore` type (`FriendRoster`) covered by `swift test`; `GroupsSession` holds state and calls it. Tests the earlier items called "core tests of `GroupsSession`" are tests of this type. Anything that needs the session itself runs app-hosted, as `ProposalSessionTests` does.
- EN14 Expiry is decided by the server. `friend_link()` returns the expiry and an `expired` flag; the app shows the state it is given and only formats the date. The in-memory store uses the injected clock (`-FriendCalNow`).
- EN15 (refines R25) Preview returns the inviter's id as well as the name. The recipient's saved set gains that id when Connect is tapped, before the call, so a reply lost after the server committed cannot produce a second "joined" announcement. A retry that answers "already friends" after the person's own Connect is shown as success.
- EN16 Landing page and link parsing (T4). The page sends `Referrer-Policy: no-referrer` and loads no third-party script, font or analytics, so the token in the path goes nowhere else. `DeepLink` accepts the https form only for host `friendcal.app` exactly and path `/f/<token>` exactly; anything else is not a link. Test: `DeepLink` unit tests for a wrong host, extra path parts and tokens of 21 and 23 characters.
- EN17 (refines R29) `friend_links` also keeps `mint_count`. `accept_count` and `mint_count` are lifetime totals for the person and survive a reset.
- EN18 A token stops working after 50 accepts and answers like any dead link; a reset starts a new count. Test: SQL test at the boundary.
- EN19 Accept, preview and the link functions refuse a caller with no active `users` row with the existing `FC_ACCOUNT_DELETED` refusal. Test: SQL test.
- EN20 Three pull requests, in order: SQL (T1); app with the sheet reachable only from the debug sheet (T2, T3, T5); web, universal links and entry points together (T4, T6). T1 is re-estimated to human ~3d / CC ~2.5h.
<!-- /autoplan-accepted:eng -->

#### NOT in scope (eng)
One shared table of answer cases run through both the Swift and SQL lanes (Claude L7): useful, and more machinery than six cases need; the in-memory store keeps its own tests. Per-caller rate limits on preview and accept: one account can accept a link once, and the cap (EN18) bounds a leaked link. Storing the token hashed: Reset is one tap and the table has no client access. A name step before the first Connect (EN9): TODO.

#### What already exists (eng)
Reused as is: `friendcal_lock_users` (`lock_proposal.sql:32`), `is_active` (`users_auth.sql:75`), the compose-the-push-in-the-transaction rule (`social.sql:32`), the self-check pattern (`social.sql:444`), `t.call`/`t.uh` (`helpers.sql:72`, `:35`), the both-lanes upgrade harness (`test-sql.sh:163`), `XCUIDevice.shared.system.open` for link tests (`LockedInviteUITests.swift:322`), `failNext` and its launch argument (`FriendCalApp.swift:47`), `SocialInbox.unknownName`. Rebuilt: the pending-link replay, because it never worked.

#### Failure modes (eng)
| Path | Realistic failure | Test | Handling | Seen by the user |
|---|---|---|---|---|
| Link opened while signed out | dropped (today) | EN1 UI test | router stores it | Lands on the invite or Accept after sign-in |
| Accept vs account deletion | friendship beside a tombstone | EN4 SQL two-order test | caller in lock set | "This link doesn't work anymore." or connected, never both |
| Poke vs removal | poke after removal | EN2 SQL test | re-check after lock | "You can only poke friends." |
| Reset reply lost | dead link shown as live | EN12 core test | re-read before enabling | Retry, then the real link |
| Stale refresh | removed friend reappears | EN11 core test | generation | Nothing wrong on screen |
| Token minted on Supabase | function not found | EN3 SQL test | no extension used | Not reachable |
| `anon` calls preview | name leak without sign-in | EN6 `t.call` test | revoke + self-check | Refused |
| Old `push_outbox` upgraded | constraint blocks apply | EN10 upgrade lane | re-runnable swap | Not reachable |
| Link over an open sheet | Accept never shows | EN8 UI test | shown on sheet close | Accept after closing the sheet |
| AASA or host broken | link opens Safari or errors | manual, device | rollback by DNS | Browser page or error |
Critical gaps (no test, no handling, silent): 1 today, the dropped signed-out link, closed by EN1. 0 after the accepted items. The last row is tested by hand only and is visible when it fails.

#### Worktree parallelization
| Step | Modules touched | Depends on |
|---|---|---|
| T1 SQL | `supabase/`, `scripts/` | — |
| T2+T3+T5 app | `app/FriendCal/Models`, `Services`, `Views`, tests | the store protocol only (in-memory store first) |
| T4 web | new static site, `app/project.yml`, `DeepLink` constant | domain; T2+T3 for the app side |
| T6 entry points | `app/FriendCal/Views/Groups`, `Home` | T4 |
Lane A: T1. Lane B: T2 → T3 → T5 (shared `Services/` and `Views/Shell`, so in order). Launch A and B together; the app is built against the in-memory store, then `SupabaseProposalStore` is wired when A merges. Then T4, then T6. Conflict flag: `InMemoryProposalStore.swift` and `ProposalStore.swift` are touched only in lane B.

#### Eng completion summary
- Step 0: Scope Challenge — scope accepted as-is (4 findings, 1 critical)
- Reality rows: 8/8 applicable rows emitted, 2 unverified premises
- Architecture Review: 7 issues found
- Code Quality Review: 7 issues found
- Test Review: diagram produced, 49 gaps identified, all accepted as required tests
- Performance Review: 2 issues found
- NOT in scope: written
- What already exists: written
- TODOS.md updates: 7 items proposed (6 from earlier phases, 1 new), written at approval
- Failure modes: 1 critical gap flagged, closed by EN1
- Unresolved decisions: 0 new in this phase; UC1-UC7, d3-d5 and the domain question remain for the gate
- Outside voice: codex, completed (11 findings)
- Parallelization: 2 lanes, 2 parallel then 2 sequential steps
- Lake Score: N/A (no coverage-scored questions were asked; decisions were made under /autoplan)

### Phase 4: Final gate
Presented 2026-11-10, gate_rev 1. Owner reply: `rec` (every recommendation, plan changes included). Status: APPROVED.

| Item | Answer |
|---|---|
| uc1 share message and accept line | a: reworded to what ships |
| uc2 "ask to connect" | a: "Anyone who opens it can connect with you" |
| uc3 connect through plans | b: not in this plan; TODOS.md entry |
| uc4 short code | a: dropped; "tap the link again" |
| uc5 7-day expiry | a: no expiry |
| uc6 seat cards as entry point | a: left alone |
| uc7 VoiceOver announcements | a: three added |
| q1 friendcal.app | a: owned or being acquired; T4 prerequisites start with T1 |
| d3 plan links in T4 | a: included |
| d4 push forwarder | a: own plan, next |
| d5 wording pack | a: taken |
| d6 token strength | a: 122 bits, no pgcrypto |
| d7 link over an open sheet | a: Accept shows when the sheet closes |
| p1 the plan | b: approved with the recommended changes |

The approved build spec, with every accepted item and these answers folded into one text, is `docs/designs/friendcal-add-friend-spec.md` (this satisfies R31). Build from that file; this file is the record of why. The gate's plan changes were not sent back through the review phases a second time: each is a change the reviewers themselves proposed, and most remove scope (expiry, short code, seat cards). TODOS.md gained eight entries under "Friends". The test plan predates the gate and still lists expiry cases; the spec's section 8 is current.
