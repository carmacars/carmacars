import { test } from 'node:test';
import assert from 'node:assert/strict';
import { BLOCKED_BOT, shield, shieldResponse } from './bot-shield.ts';
import { BLOCKED_CRAWLERS } from '../../features/seo/crawlers.ts';

const CHROME = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36';
const GOOGLE = 'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)';
const AHREFS = 'Mozilla/5.0 (compatible; AhrefsBot/7.0; +http://ahrefs.com/robot/)';
const HEADLESS = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/130.0 Safari/537.36';
const u = (p: string) => `https://carmacars.ca${p}`;

test('people, headless browsers (the e2e tests) and scripts pass everywhere', () => {
  for (const ua of [CHROME, HEADLESS, 'curl/8.5.0', 'WhatsApp/2.23', null]) {
    for (const p of ['/', '/admin', '/cars?make=bmw', '/cars/bmw/x5?utm_source=x', '/book/abc']) assert.equal(shield('GET', u(p), ua).kind, 'pass', `${ua} ${p}`);
  }
});

test('SEO tools and scrapers: 403 on every page but robots.txt and the API', () => {
  assert.deepEqual(shield('GET', u('/cars/bmw/x5'), AHREFS), { kind: 'refuse', reason: 'blocked' });
  assert.deepEqual(shield('GET', u('/'), 'Mozilla/5.0 (Linux; Android 5.0) AppleWebKit/537.36 (KHTML, like Gecko) Mobile Safari/537.36 (compatible; Bytespider; spider-feedback@bytedance.com)'), { kind: 'refuse', reason: 'blocked' });
  assert.equal(shield('GET', u('/robots.txt'), AHREFS).kind, 'pass');
  assert.equal(shield('POST', u('/cars'), AHREFS).kind, 'pass');
  assert.equal(shield('GET', u('/api/health'), AHREFS).kind, 'pass');
  for (const b of BLOCKED_CRAWLERS) assert.ok(BLOCKED_BOT.test(`Mozilla/5.0 (compatible; ${b}/1.0)`), b);
});

test('a crawler on a portal or sign-in page: 403; on a public page: pass', () => {
  for (const p of ['/admin/bookings/CC-1', '/staff', '/staff/field', '/va', '/sign-in', '/account/bookings/x', '/book/x']) assert.deepEqual(shield('GET', u(p), GOOGLE), { kind: 'refuse', reason: 'portal' }, p);
  for (const p of ['/', '/cars', '/cars/bmw/x5', '/guides/winter-tires', '/r/abc', '/go/x', '/sitemap.xml']) assert.equal(shield('GET', u(p), GOOGLE).kind, 'pass', p);
});

test('a crawler on a query-string view robots.txt keeps out: 301 to the clean address', () => {
  assert.deepEqual(shield('GET', u('/cars?make=bmw&from=2026-11-01'), GOOGLE), { kind: 'redirect', location: 'https://carmacars.ca/cars' });
  assert.deepEqual(shield('GET', u('/car-rental/toronto?utm_source=x'), GOOGLE), { kind: 'redirect', location: 'https://carmacars.ca/car-rental/toronto' });
  assert.equal(shield('GET', u('/cars/bmw/x5?_rsc=1'), GOOGLE).kind, 'pass');
  assert.equal(shield('GET', u('/?ref=x'), GOOGLE).kind, 'pass');
  assert.equal(shield('GET', u('/guides?page=2'), GOOGLE).kind, 'pass');
});

test('the answers: 403 with noindex, cached; 301 cached a day', () => {
  const r = shieldResponse({ kind: 'refuse', reason: 'blocked' }, { 'x-test': '1' });
  assert.equal(r.status, 403);
  assert.equal(r.headers.get('x-robots-tag'), 'noindex');
  assert.equal(r.headers.get('cache-control'), 'public, max-age=86400');
  assert.equal(r.headers.get('x-test'), '1');
  const m = shieldResponse({ kind: 'redirect', location: 'https://carmacars.ca/cars' }, {});
  assert.equal(m.status, 301);
  assert.equal(m.headers.get('location'), 'https://carmacars.ca/cars');
});
