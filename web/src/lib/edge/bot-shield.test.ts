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

// 0324: every crawler reaches every page; while the month's crawler guard is on, the crawlers that are not search or
// answer crawlers keep to the crawl scope; search and answer crawlers never do (only the Core search scope limits them)
import { isSearchCrawler, keptToScope } from './bot-shield.ts';
import { FULL_SCOPE_CRAWLERS } from '../../features/seo/crawlers.ts';
test('the crawler guard: training and unnamed crawlers on deep pages only while it is on; search crawlers never', async () => {
  const deep = '/cars/bmw/x5/2021/xdrive40i/black';
  const GPT = 'Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; GPTBot/1.2; +https://openai.com/gptbot)';
  const off = async () => false, on = async () => true;
  assert.equal(await keptToScope(GPT, deep, off, off), false, 'guard off: every page');
  assert.equal(await keptToScope('Mozilla/5.0 (compatible; ClaudeBot/1.0; +claudebot@anthropic.com)', deep, off, off), false);
  assert.equal(await keptToScope(GPT, deep, off, on), true, 'guard on: the crawl scope');
  assert.equal(await keptToScope('SomeNewBot/1.0', deep, off, on), true);
  assert.equal(await keptToScope(GOOGLE, deep, off, on), false, 'search crawlers are never limited by the guard');
  assert.equal(await keptToScope('Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko; compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)', deep, off, on), false);
  assert.equal(await keptToScope(GOOGLE, deep, on, on), true, 'Core: search crawlers too');
  assert.equal(await keptToScope(GPT, '/cars/bmw/x5', off, on), false, 'inside the scope: open to all');
  assert.equal(await keptToScope(CHROME, deep, on, on), false, 'people: every page');
  let reads = 0;
  await keptToScope(GOOGLE, deep, off, async () => { reads++; return true; });
  assert.equal(reads, 0, 'the guard flag is not read for a search crawler');
  for (const b of FULL_SCOPE_CRAWLERS) assert.ok(isSearchCrawler(`Mozilla/5.0 (compatible; ${b}/1.0)`), b);
  assert.equal(isSearchCrawler('Mozilla/5.0 (compatible; Applebot-Extended/1.0)'), false);
});

