# friendcal.app

Everything that is served lives in `site/public/`; this README and `test/` are not deployed.

The static site behind FriendCal's shared links (docs/designs/friendcal-add-friend-spec.md, 4.8). No build step, no framework, no dependencies, and no third-party script, font or analytics.

| Path | What |
|---|---|
| `/f/<token>`, `/p/<uuid>` | Landing pages for friend and plan links (`_redirects` rewrites both to one static page each: `f.html`, `p.html`). `noindex`, `Referrer-Policy: no-referrer`, name/title hint written with `textContent` only |
| `/.well-known/apple-app-site-association` | Universal links for app ID `6589A6M74D.com.friendcal.app`, paths `/f/*` and `/p/*`. Served as `application/json`, never redirected |
| `/` | A one-screen home page |

The public TestFlight link lives in ONE place: `TESTFLIGHT_URL` at the top of `public/landing.js` (the three `href`s in the HTML are the same value; the test fails if they drift).

Test: `node --test site/test/landing.test.mjs` (Node 20+).

## Deploying on Cloudflare Pages

The domain is on Cloudflare, so Pages needs no DNS records to edit by hand. `_headers` and `_redirects` are Pages' format for the rules (headers, rewrites).

1. `npx wrangler login` once, then from the repo root: `npx wrangler pages deploy site/public --project-name friendcal --branch main`. (First run creates the project.)
2. In the Cloudflare dashboard: Workers & Pages, the `friendcal` project, Custom domains, add `friendcal.app` (Cloudflare adds the DNS record and the certificate itself) and `www.friendcal.app`.
3. Check from a terminal, with no redirect in the way:
   `curl -sI https://friendcal.app/.well-known/apple-app-site-association` must answer `200` and `content-type: application/json`.
   `curl -sI https://friendcal.app/f/AbCdEfGhIjKlMnOpQr_-12` must answer `200` (a rewrite), carry `x-robots-tag: noindex` and `referrer-policy: no-referrer`.
4. Leave Cloudflare's "Auto Minify", "Rocket Loader", "Email Address Obfuscation" and any "Bot Fight" rule that challenges Apple's fetch OFF for this zone: each rewrites or blocks files the page and the association file must serve untouched.
5. Apple caches the association file (through its CDN) for hours to a day, so a first install can lag. Re-install the app after the file is live.
