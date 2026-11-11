// The landing pages' logic, in one file with no dependencies. Loaded by /f/index.html and
// /p/index.html from the same origin (the page loads no third-party script, font or analytics), and
// imported by test/landing.test.mjs.
//
// The name and title hints come from the URL, so they are attacker-controlled text. They are cleaned
// here the same way DeepLink.sanitizedTitle cleans them in the app, capped, and only ever written
// with textContent -- never innerHTML, never into an attribute.
(function (root) {
  'use strict';

  // The ONE place the public TestFlight link lives. Change it here and nowhere else.
  var TESTFLIGHT_URL = 'https://testflight.apple.com/join/fq7G4p4s';

  var TOKEN = /^[A-Za-z0-9_-]{22}$/;
  var UUID = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
  var MAX_NAME = 40;   // DeepLink.maxNameLength
  var MAX_TITLE = 80;  // DeepLink.maxTitleLength

  // Mirrors DeepLink.sanitizedTitle: control characters, zero-width and joiner marks, bidi
  // embeddings/overrides/isolates, the BOM; trimmed; capped by code points; empty becomes null.
  function clean(raw, cap) {
    if (typeof raw !== 'string') return null;
    var out = '';
    for (var ch of raw) {
      var c = ch.codePointAt(0);
      if (c <= 0x1F || (c >= 0x7F && c <= 0x9F)) continue;                 // control characters
      if (c >= 0x200B && c <= 0x200F) continue;                            // zero-width, LTR/RTL marks
      if (c >= 0x202A && c <= 0x202E) continue;                            // bidi embedding and override
      if (c >= 0x2060 && c <= 0x206F) continue;                            // word joiner, bidi isolates
      if (c === 0xFEFF) continue;                                          // BOM
      if (c === 0x2028 || c === 0x2029) continue;                          // line and paragraph separators
      out += ch;
    }
    out = out.trim();
    if (!out) return null;
    return Array.from(out).slice(0, cap).join('');
  }

  // /f/<token> and /p/<uuid>, matched exactly: one more path part, or a malformed id, is no link.
  function parsePath(pathname) {
    var parts = String(pathname).split('/').filter(function (p) { return p.length > 0; });
    if (parts.length !== 2) return null;
    if (parts[0] === 'f' && TOKEN.test(parts[1])) return { kind: 'friend', id: parts[1] };
    if (parts[0] === 'p' && UUID.test(parts[1])) return { kind: 'plan', id: parts[1].toLowerCase() };
    return null;
  }

  // Facebook, Instagram, Messenger, Line, Twitter/X, TikTok, Snapchat, WeChat, LinkedIn, Gmail, Google
  // app: browsers that can't hand a universal link to an installed app, so the page shows a button.
  function isInAppBrowser(ua) {
    return /FBAN|FBAV|FB_IAB|Instagram|Line\/|Twitter|TikTok|musical_ly|Snapchat|MicroMessenger|LinkedInApp|GSA\/|Gmail/i.test(ua || '');
  }

  // FriendCal is on iPhone for now. iPad and Mac Safari can claim to be a Mac, so "iPhone" is the test.
  function isIPhone(ua) { return /iPhone/.test(ua || ''); }

  // Where "Open in FriendCal" goes: the custom-scheme form of the same link, hint included.
  function appURL(kind, id, hint) {
    var base = kind === 'friend' ? 'friendcal://friend/' + id : 'friendcal://proposal/' + id;
    if (!hint) return base;
    return base + '?' + (kind === 'friend' ? 'n' : 't') + '=' + encodeURIComponent(hint);
  }

  // Everything the page says, as plain strings, so the test asserts the words without a browser.
  function copy(link, hint) {
    if (link.kind === 'friend') {
      return {
        headline: (hint || 'A friend') + ' wants to connect on FriendCal',
        body: 'FriendCal finds a time that works for your whole friend group, so planning stops being a group chat.',
        after: 'After installing, tap ' + (hint ? hint + "'s" : 'your friend\'s') + ' link again.'
      };
    }
    return {
      headline: hint ? 'You were invited to ' + hint : 'You were invited to a plan',
      body: 'FriendCal finds a time that works for your whole friend group, so planning stops being a group chat.',
      after: 'After installing, tap the invite link again.'
    };
  }

  function render(doc, loc, ua) {
    var link = parsePath(loc.pathname);
    var params = new URLSearchParams(loc.search);
    var hint = link ? clean(params.get(link.kind === 'friend' ? 'n' : 't'), link.kind === 'friend' ? MAX_NAME : MAX_TITLE) : null;
    var words = link ? copy(link, hint) : {
      headline: "This link doesn't look right",
      body: 'FriendCal finds a time that works for your whole friend group.',
      after: ''
    };
    function set(id, text) { doc.getElementById(id).textContent = text; }   // textContent only
    set('headline', words.headline);
    set('body', words.body);
    set('after', words.after);

    var cta = doc.getElementById('cta');
    var open = doc.getElementById('open');
    var note = doc.getElementById('note');
    if (!isIPhone(ua)) {
      // No install button where there is nothing to install.
      cta.hidden = true;
      open.hidden = true;
      set('after', '');
      set('note', 'FriendCal is on iPhone for now');
      note.hidden = false;
      return;
    }
    cta.setAttribute('href', TESTFLIGHT_URL);
    if (link && isInAppBrowser(ua)) {
      open.setAttribute('href', appURL(link.kind, link.id, hint));
      open.hidden = false;
    }
  }

  var api = { TESTFLIGHT_URL: TESTFLIGHT_URL, clean: clean, parsePath: parsePath, isInAppBrowser: isInAppBrowser,
              isIPhone: isIPhone, appURL: appURL, copy: copy, render: render, MAX_NAME: MAX_NAME, MAX_TITLE: MAX_TITLE };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  root.FriendCalLanding = api;
})(typeof window !== 'undefined' ? window : globalThis);
