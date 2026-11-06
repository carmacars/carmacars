import { test } from 'node:test';
import assert from 'node:assert/strict';
import { checkPage, httpsRedirect, knownBrowser, longTail, scraperGuard, tooMany, verifiedBot } from './scraper-guard.ts';

const place = '/car-rental/cars-for-hire/valle-el-coriejo-mex';
test('a hosting network gets only kept copies of the long-tail pages; people and verified bots always pass', () => {
  assert.equal(scraperGuard('GET', place, { asOrganization: 'RapidSeedbox Ltd' }), 'copy-only');
  assert.equal(scraperGuard('GET', '/buy/cars-for-sale/rancho-el-fresno-gua', { asOrganization: 'Hetzner Online GmbH' }), 'copy-only');
  assert.equal(scraperGuard('GET', place, { asOrganization: 'RapidSeedbox Ltd', verifiedBotCategory: 'AI Crawler' }), 'pass', 'a verified bot');
  assert.equal(scraperGuard('GET', place, { asOrganization: 'Google LLC', verifiedBotCategory: 'Search Engine Crawler' }), 'pass');
  for (const org of ['Rogers Communications Canada Inc.', 'Bell Canada', 'Virgin Media Limited', 'Microsoft Corporation', 'OVH SAS', 'Apple Inc.', 'Anthropic, PBC', 'Amazon.com, Inc.']) {
    assert.equal(scraperGuard('GET', place, { asOrganization: org }), 'pass', org);
  }
  assert.equal(scraperGuard('GET', '/', { asOrganization: 'RapidSeedbox Ltd' }), 'pass', 'not a long-tail page');
  assert.equal(scraperGuard('GET', '/cars', { asOrganization: 'RapidSeedbox Ltd' }), 'pass');
  assert.equal(scraperGuard('POST', place, { asOrganization: 'RapidSeedbox Ltd' }), 'pass');
  assert.equal(scraperGuard('GET', place, undefined), 'pass');
  assert.ok(longTail('/cars/bmw/x5/2021/xdrive40i/black') && longTail('/detailing/hand-car-wash/la-providencia-tenancingo-mex') && !longTail('/guides/winter-tires'));
  assert.ok(verifiedBot({ botManagement: { verifiedBot: true } }) && !verifiedBot({ verifiedBotCategory: '' }));
});

test('http on the site\'s hosts redirects to https; other hosts and https do not', () => {
  assert.equal(httpsRedirect('http://carmacars.ca/car-rental/x/y?a=1'), 'https://carmacars.ca/car-rental/x/y?a=1');
  assert.equal(httpsRedirect('http://www.carmacars.ca/'), 'https://www.carmacars.ca/');
  assert.equal(httpsRedirect('https://carmacars.ca/'), null);
  assert.equal(httpsRedirect('http://localhost:3000/'), null);
  assert.equal(httpsRedirect('http://carmacars.ca.example.test/'), null);
});

test('429 with Retry-After, never cached', () => {
  const r = tooMany(3600);
  assert.equal(r.status, 429);
  assert.equal(r.headers.get('retry-after'), '3600');
  assert.equal(r.headers.get('cache-control'), 'no-store');
});

test('a browser-looking agent without our cookies is checked on long-tail pages; crawlers, scripts and known browsers are not', () => {
  const chrome = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36';
  const isp = { asOrganization: 'Virgin Media Limited' };
  assert.equal(scraperGuard('GET', place, isp, chrome, null), 'check');
  assert.equal(scraperGuard('GET', place, isp, chrome, 'cc_geo=CA-ON'), 'pass', 'a browser that keeps our cookies');
  assert.equal(scraperGuard('GET', place, isp, chrome, 'cc_h=1'), 'pass');
  assert.equal(scraperGuard('GET', place, isp, chrome, null, true), 'pass', 'the router');
  assert.equal(scraperGuard('GET', place, { ...isp, verifiedBotCategory: 'AI Search' }, chrome, null), 'pass');
  for (const ua of ['Mozilla/5.0 (compatible; GPTBot/1.2; +https://openai.com/gptbot)', 'Mozilla/5.0 (compatible; Claude-User/1.0)', 'curl/8.5.0', 'CarmaCars warm-up (cron)',
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/130.0 Safari/537.36', '']) assert.equal(scraperGuard('GET', place, isp, ua, null), 'pass', ua);
  assert.equal(scraperGuard('GET', '/', isp, chrome, null), 'pass', 'home is never checked');
  assert.equal(scraperGuard('GET', '/cars/bmw', isp, chrome, null), 'pass');
  assert.ok(knownBrowser('a=1; sb-abc123-auth-token=x') && !knownBrowser('cc_geox=1'));
  const r = checkPage();
  assert.equal(r.status, 200);
  assert.equal(r.headers.get('cache-control'), 'no-store');
});

import { BUSY_TRIP, BUSY_WINDOW_MS, BusyMeter, renderFailed } from './scraper-guard.ts';
test('cached-only mode trips after repeated failed renders within a minute, at most once a minute per isolate', () => {
  const m = new BusyMeter();
  const t0 = 1_800_000_000_000;
  for (let i = 0; i < BUSY_TRIP - 1; i++) assert.equal(m.failed(t0 + i), false);
  assert.equal(m.failed(t0 + 10), true);
  assert.equal(m.failed(t0 + 20), false, 'not again within the minute');
  const late = new BusyMeter();
  for (let i = 0; i < BUSY_TRIP; i++) assert.equal(late.failed(t0 + i * BUSY_WINDOW_MS), false, 'spread out: never');
  assert.ok(renderFailed(503, null) && renderFailed(200, 'slow') && renderFailed(200, 'error 502; age=3') && !renderFailed(200, null) && !renderFailed(404, null));
});
