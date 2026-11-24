import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cspHeader, securityHeaders } from './csp.ts';

// hotfix 3420: Stripe.js starts its Payment Element frames on subdomains of js.stripe.com and Link on link.com; a policy
// without them left the card box empty on Sign and pay.
test('the policy lets the Stripe Payment Element load its frames and scripts', () => {
  const p = Object.fromEntries(cspHeader('n').split('; ').map((d) => { const [k, ...v] = d.split(' '); return [k!, v]; }));
  for (const o of ['https://js.stripe.com', 'https://*.js.stripe.com']) {
    assert.ok(p['script-src']!.includes(o), `script-src ${o}`);
    assert.ok(p['frame-src']!.includes(o), `frame-src ${o}`);
  }
  for (const o of ['https://hooks.stripe.com', 'https://link.com', 'https://*.link.com']) assert.ok(p['frame-src']!.includes(o), `frame-src ${o}`);
  assert.ok(p['connect-src']!.includes('https://api.stripe.com'));
});

test('wallets (Apple Pay, Google Pay) may run in Stripe\'s frame', () => {
  assert.match(securityHeaders()['Permissions-Policy']!, /payment=\(self "https:\/\/js\.stripe\.com" "https:\/\/\*\.js\.stripe\.com" "https:\/\/secure\.helcim\.app"\)/);
});

// r50: Helcim replaces Stripe for cards. HelcimPay.js (script) and its card modal (iframe) come from secure.helcim.app;
// the API (api.helcim.com) is called only by the server, never allowed to the browser.
test('the policy lets HelcimPay.js load its script and card modal, never the Helcim API', () => {
  const p = Object.fromEntries(cspHeader('n').split('; ').map((d) => { const [k, ...v] = d.split(' '); return [k!, v]; }));
  for (const k of ['script-src', 'frame-src', 'connect-src']) assert.ok(p[k]!.includes('https://secure.helcim.app'), `${k} secure.helcim.app`);
  assert.ok(!cspHeader('n').includes('api.helcim.com'));
});
