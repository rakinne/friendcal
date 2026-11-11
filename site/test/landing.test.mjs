// Run with: node --test site/test   (no dependencies)
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const require = createRequire(import.meta.url);
const here = path.dirname(fileURLToPath(import.meta.url));
const site = path.join(here, '..', 'public');
const L = require('../public/landing.js');
const read = (p) => readFileSync(path.join(site, p), 'utf8');

const TOKEN = 'AbCdEfGhIjKlMnOpQr_-12';
const IPHONE = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';

test('the hint is cleaned like DeepLink.sanitizedTitle', () => {
  assert.equal(L.clean('Sam', 40), 'Sam');
  assert.equal(L.clean('  Sam  ', 40), 'Sam');
  assert.equal(L.clean('‮evil', 40), 'evil', 'bidi override removed');
  assert.equal(L.clean('Bru​nch', 80), 'Brunch', 'zero-width removed');
  assert.equal(L.clean('a⁦b⁩c', 80), 'abc', 'bidi isolates removed');
  assert.equal(L.clean('Line\nbreak\ttab', 80), 'Linebreaktab', 'control characters removed');
  assert.equal(L.clean('Café 🥐', 80), 'Café 🥐', 'ordinary text and emoji survive');
  assert.equal(L.clean('', 40), null);
  assert.equal(L.clean('   \n ', 40), null);
  assert.equal(L.clean(null, 40), null);
  assert.equal(L.clean('‮', 40), null, 'a hint that cleans to nothing is no hint');
});

test('the hint is capped by characters: 40 for a name, 80 for a title', () => {
  assert.equal(Array.from(L.clean('b'.repeat(100), L.MAX_NAME)).length, 40);
  assert.equal(Array.from(L.clean('b'.repeat(100), L.MAX_TITLE)).length, 80);
  assert.equal(Array.from(L.clean('🥐'.repeat(100), L.MAX_NAME)).length, 40, 'counted in code points, never splitting one');
});

test('markup in a hint stays text', () => {
  const hostile = '<img src=x onerror=alert(1)>';
  assert.equal(L.clean(hostile, 40), hostile.slice(0, 40), 'cleaning does not interpret markup; textContent does the rest');
});

test('paths: exactly /f/<22 chars> or /p/<uuid>', () => {
  assert.deepEqual(L.parsePath('/f/' + TOKEN), { kind: 'friend', id: TOKEN });
  assert.deepEqual(L.parsePath('/f/' + TOKEN + '/'), { kind: 'friend', id: TOKEN });
  assert.deepEqual(L.parsePath('/p/00000000-0000-0000-0000-000000000900'), { kind: 'plan', id: '00000000-0000-0000-0000-000000000900' });
  for (const bad of ['/f/' + TOKEN.slice(1), '/f/' + TOKEN + 'A', '/f/' + TOKEN + '/extra', '/f', '/', '/x/' + TOKEN,
                     '/f/' + TOKEN.slice(1) + '+', '/p/not-a-uuid', '/p/' + TOKEN]) {
    assert.equal(L.parsePath(bad), null, bad);
  }
});

test('in-app browsers are told apart; Safari is not', () => {
  assert.equal(L.isInAppBrowser(IPHONE), false);
  assert.equal(L.isInAppBrowser(IPHONE + ' [FBAN/FBIOS;FBAV/450.0]'), true);
  assert.equal(L.isInAppBrowser(IPHONE + ' Instagram 300.0'), true);
  assert.equal(L.isInAppBrowser(IPHONE + ' Line/13.0'), true);
  assert.equal(L.isInAppBrowser(IPHONE + ' Twitter for iPhone'), true);
  assert.equal(L.isIPhone(IPHONE), true);
  assert.equal(L.isIPhone('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15'), false);
  assert.equal(L.isIPhone('Mozilla/5.0 (Linux; Android 14) Chrome/120 Mobile'), false);
});

test('the page says what the spec says', () => {
  assert.deepEqual(L.copy({ kind: 'friend' }, 'Sam'), {
    headline: 'Sam wants to connect on FriendCal',
    body: 'FriendCal finds a time that works for your whole friend group, so planning stops being a group chat.',
    after: "After installing, tap Sam's link again."
  });
  assert.equal(L.copy({ kind: 'friend' }, null).headline, 'A friend wants to connect on FriendCal');
  assert.equal(L.copy({ kind: 'plan' }, 'Brunch').headline, 'You were invited to Brunch');
  assert.equal(L.copy({ kind: 'plan' }, null).headline, 'You were invited to a plan');
});

test('Open in FriendCal carries the same link and a re-encoded hint', () => {
  assert.equal(L.appURL('friend', TOKEN, 'Sam'), 'friendcal://friend/' + TOKEN + '?n=Sam');
  assert.equal(L.appURL('friend', TOKEN, null), 'friendcal://friend/' + TOKEN);
  assert.equal(L.appURL('friend', TOKEN, 'a&b=c'), 'friendcal://friend/' + TOKEN + '?n=a%26b%3Dc', 'no hint can add a query item');
  assert.equal(L.appURL('plan', '00000000-0000-0000-0000-000000000900', 'Brunch'), 'friendcal://proposal/00000000-0000-0000-0000-000000000900?t=Brunch');
});

// A tiny DOM: enough to prove render() writes with textContent and never touches innerHTML.
function fakeDoc() {
  const nodes = {};
  for (const id of ['headline', 'body', 'after', 'note', 'cta', 'open']) {
    nodes[id] = { id, hidden: id === 'open' || id === 'note', attrs: {}, _text: '',
      set textContent(v) { this._text = v; }, get textContent() { return this._text; },
      set innerHTML(v) { throw new Error('innerHTML must never be used'); },
      setAttribute(k, v) { this.attrs[k] = v; } };
  }
  return { nodes, getElementById: (id) => nodes[id] };
}

test('render: friend link on iPhone Safari', () => {
  const doc = fakeDoc();
  L.render(doc, { pathname: '/f/' + TOKEN, search: '?n=Sam' }, IPHONE);
  assert.equal(doc.nodes.headline.textContent, 'Sam wants to connect on FriendCal');
  assert.equal(doc.nodes.after.textContent, "After installing, tap Sam's link again.");
  assert.equal(doc.nodes.cta.attrs.href, L.TESTFLIGHT_URL);
  assert.equal(doc.nodes.open.hidden, true, 'no Open button outside an in-app browser');
});

test('render: in-app browser gets a visible Open in FriendCal button', () => {
  const doc = fakeDoc();
  L.render(doc, { pathname: '/f/' + TOKEN, search: '?n=Sam' }, IPHONE + ' Instagram 300.0');
  assert.equal(doc.nodes.open.hidden, false);
  assert.equal(doc.nodes.open.attrs.href, 'friendcal://friend/' + TOKEN + '?n=Sam');
});

test('render: non-iPhone sees FriendCal is on iPhone for now and no install button', () => {
  const doc = fakeDoc();
  L.render(doc, { pathname: '/f/' + TOKEN, search: '?n=Sam' }, 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Safari/605.1.15');
  assert.equal(doc.nodes.note.textContent, 'FriendCal is on iPhone for now');
  assert.equal(doc.nodes.note.hidden, false);
  assert.equal(doc.nodes.cta.hidden, true);
  assert.equal(doc.nodes.open.hidden, true);
  assert.equal(doc.nodes.cta.attrs.href, undefined, 'no TestFlight link is wired for them');
});

test('render: a hostile hint reaches the page as plain text, bidi stripped', () => {
  const doc = fakeDoc();
  const hint = encodeURIComponent('‮<img src=x onerror=alert(1)>');
  L.render(doc, { pathname: '/f/' + TOKEN, search: '?n=' + hint }, IPHONE);
  assert.equal(doc.nodes.headline.textContent, '<img src=x onerror=alert(1)> wants to connect on FriendCal');
});

test('render: a bad path says so and never echoes the URL', () => {
  const doc = fakeDoc();
  L.render(doc, { pathname: '/f/short', search: '?n=Sam' }, IPHONE);
  assert.equal(doc.nodes.headline.textContent, "This link doesn't look right");
  assert.ok(!doc.nodes.headline.textContent.includes('Sam'));
});

test('the pages: no third-party host, no inline script, no innerHTML, noindex, and the TestFlight link matches', () => {
  for (const page of ['index.html', 'f.html', 'p.html']) {
    const html = read(page);
    assert.ok(!/<script(?![^>]*\bsrc=)[^>]*>/i.test(html), page + ': no inline script (the CSP forbids it)');
    for (const m of html.matchAll(/(?:src|href)="(https?:\/\/[^"]+)"/g)) {
      assert.equal(m[1], L.TESTFLIGHT_URL, page + ': the only external URL is the TestFlight link, got ' + m[1]);
    }
    assert.ok(!/style=/.test(html), page + ': no inline style (the CSP forbids it)');
  }
  for (const page of ['f.html', 'p.html']) {
    assert.match(read(page), /name="robots" content="noindex/, page + ' is noindex');
  }
  assert.ok(!read('landing.js').includes('.innerHTML'), 'landing.js never uses innerHTML');
  assert.ok(!/https?:\/\/(?!testflight\.apple\.com)/.test(read('landing.js').replace(/\/\/ .*$/gm, '')), 'landing.js names no other host');
});

test('apple-app-site-association: the app, the two paths, valid JSON', () => {
  const aasa = JSON.parse(read('.well-known/apple-app-site-association'));
  const detail = aasa.applinks.details[0];
  assert.deepEqual(detail.appIDs, ['6589A6M74D.com.friendcal.app']);
  assert.deepEqual(detail.components.map((c) => c['/']).sort(), ['/f/*', '/p/*']);
});

// Cloudflare Pages config: _redirects (rewrites) and _headers, parsed the way Pages reads them.
function parseHeaders(text) {
  const blocks = {};
  let current = null;
  for (const line of text.split('\n')) {
    if (!line.trim() || line.trim().startsWith('#')) continue;
    if (!/^\s/.test(line)) { current = line.trim(); blocks[current] = {}; continue; }
    const i = line.indexOf(':');
    blocks[current][line.slice(0, i).trim()] = line.slice(i + 1).trim();
  }
  return blocks;
}

test('_redirects: the two landing pages are rewrites (200), and nothing redirects the AASA path', () => {
  const rules = read('_redirects').split('\n').filter((l) => l.trim() && !l.trim().startsWith('#')).map((l) => l.trim().split(/\s+/));
  assert.deepEqual(rules.map((r) => r.join(' ')).sort(), ['/f/* /f 200', '/p/* /p 200']);
  for (const [, , status] of rules) assert.equal(status, '200', 'a rewrite, never a redirect');
  assert.ok(!rules.some((r) => r[0].includes('well-known')), 'the AASA path must never redirect');
});

test('the rewrite targets exist as pages', () => {
  assert.ok(read('f.html').includes('id="headline"'));
  assert.ok(read('p.html').includes('id="headline"'));
});

test('_headers: privacy headers everywhere, noindex on the landing paths, JSON for the AASA', () => {
  const h = parseHeaders(read('_headers'));
  assert.equal(h['/*']['Referrer-Policy'], 'no-referrer');
  assert.match(h['/*']['Content-Security-Policy'], /default-src 'none'/);
  assert.match(h['/*']['Content-Security-Policy'], /script-src 'self'/);
  assert.equal(h['/*']['X-Frame-Options'], 'DENY');
  for (const path of ['/f', '/f/*', '/p', '/p/*']) {
    assert.match(h[path]['X-Robots-Tag'], /noindex/, path);
    assert.equal(h[path]['Cache-Control'], 'no-store', path);
  }
  assert.equal(h['/.well-known/apple-app-site-association']['Content-Type'], 'application/json');
});
