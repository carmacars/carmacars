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

import { BUSY_TRIP, BUSY_WINDOW_MS, BusyMeter, USAGE_CACHED_KEY, renderFailed, tailServing } from './scraper-guard.ts';
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

test('1860: cached-only serving by usage: copy first, render on a miss; busy mode still wins', () => {
  assert.equal(tailServing(false, false), 'render');
  assert.equal(tailServing(false, true), 'copy-or-render');
  assert.equal(tailServing(true, false), 'copy-or-busy');
  assert.equal(tailServing(true, true), 'copy-or-busy');
  // 2350: a verified search engine is never given the 503 busy page for a normal page
  assert.equal(tailServing(true, false, true), 'copy-or-render');
  assert.equal(tailServing(false, false, true), 'render');
  assert.match(USAGE_CACHED_KEY, /^carmacars\//);
});

// 2350: the market (place pages outside Canada answer 404 at the edge while every region outside Canada is off)
import { foreignPlacePage, outOfMarket, verifiedSearchEngine } from './scraper-guard.ts';
test('2350: US and Mexican term-and-place pages are out of market; Canadian places, landing pages and the vehicle tree are not', () => {
  for (const p of ['/detailing/clear-bra/toddsville-ny', '/body-shop/exhaust-repair/villa-del-mar-ciudad-del-carmen-cam', '/buy/used-cars-for-sale/centerville-itawamba-county-ms',
    '/car-rental/suv-rental/austin-tx', '/car-rental/suv-rental/guadalajara-jal']) assert.ok(foreignPlacePage(p), p);
  for (const p of ['/car-rental/debit-card-car-rental/wynndel-bc', '/car-rental/rideshare-car-rental/saskatchewan', '/car-rental/suv-rental/markham-on',
    '/car-rental/car-rental-near-me', '/car-rental/toronto', '/buy/ford/f-150-ca', '/buy/honda/civic', '/car-rental/suv-rental/yyz-airport', '/cars/bmw/x5/2021/xdrive40i/austin-tx',
    '/detailing/clear-bra/kingston-on', '/car-rental/suv-rental/st-louis-qc']) assert.equal(foreignPlacePage(p), false, p);
  const r = outOfMarket();
  assert.equal(r.status, 404);
  assert.match(r.headers.get('cache-control') ?? '', /max-age=86400/);
  assert.equal(r.headers.get('x-robots-tag'), 'noindex');
  assert.ok(verifiedSearchEngine({ verifiedBotCategory: 'Search Engine Crawler' }));
  assert.equal(verifiedSearchEngine({ verifiedBotCategory: 'AI Crawler' }), false);
  assert.equal(verifiedSearchEngine(undefined), false);
});

// 2402: the market by region (Ontario only by default) and the oldest model year, answered at the edge
import { CA_CODES, MARKET_DEFAULT, MARKET_MX_BIT, MARKET_US_BIT, marketOf, marketStored, offMarketPlace, oldModelYear, oldYearGone, placeRegionBit, vehiclePageYear } from './scraper-guard.ts';
test('2402: a place page of any region that is off answers 404 at the edge; Ontario stays on', () => {
  const ontario = 1;
  for (const p of ['/car-rental/suv-rental/wynndel-bc', '/car-rental/suv-rental/st-louis-qc', '/detailing/ceramic-coating/calgary-ab', '/body-shop/collision-repair/halifax-ns',
    '/fr/car-rental/suv-rental/gatineau-qc', '/car-rental/suv-rental/austin-tx', '/car-rental/suv-rental/guadalajara-jal', '/buy/used-cars/regina-sk']) assert.ok(offMarketPlace(p, ontario), p);
  for (const p of ['/car-rental/suv-rental/markham-on', '/detailing/clear-bra/kingston-on', '/body-shop/dent-repair/the-annex-toronto-on', '/car-rental/suv-rental/yyz-airport',
    '/car-rental/car-rental-near-me', '/car-rental/toronto', '/buy/ford/f-150-ca', '/cars/bmw/x5/2021/xdrive40i/austin-tx',
    '/car-rental/suv-rental/toronto-on-3fa9c']) assert.equal(offMarketPlace(p, ontario), false, p);
  assert.ok(offMarketPlace('/car-rental/rideshare-car-rental/saskatchewan', ontario), 'a province page is its region too');
  assert.equal(placeRegionBit('/car-rental/suv-rental/markham-on'), 0);
  assert.equal(placeRegionBit('/car-rental/suv-rental/st-louis-qc'), CA_CODES.indexOf('qc'));
  assert.equal(placeRegionBit('/car-rental/suv-rental/austin-tx'), MARKET_US_BIT);
  assert.equal(placeRegionBit('/car-rental/suv-rental/guadalajara-jal'), MARKET_MX_BIT);
  assert.equal(placeRegionBit('/cars/toyota/camry'), null);
  // an Admin switches Quebec on: its places pass to the app, the others stay 404
  const withQc = ontario | (1 << CA_CODES.indexOf('qc'));
  assert.equal(offMarketPlace('/car-rental/suv-rental/st-louis-qc', withQc), false);
  assert.ok(offMarketPlace('/car-rental/suv-rental/wynndel-bc', withQc));
  assert.equal(offMarketPlace('/car-rental/suv-rental/austin-tx', ontario | (1 << MARKET_US_BIT)), false);
  // stored plus one: a key never written (0) is Ontario only
  assert.equal(marketOf(0), MARKET_DEFAULT);
  assert.equal(marketOf(null), MARKET_DEFAULT);
  assert.equal(marketOf(marketStored(0)), 0, 'every region off');
  assert.equal(marketOf(marketStored(withQc)), withQc);
});
test('2402: a vehicle page of a model year below the oldest one answers 404 at the edge, in every tree', () => {
  for (const p of ['/cars/honda/civic/2004', '/cars/honda/civic/1999/lx', '/cars/honda/civic/2001/lx/markham-on/black', '/buy/honda/civic/2003', '/t/car-detailing/honda/civic/2004/ex',
    '/fr/cars/honda/civic/2002/lx', '/fr/t/car-detailing/honda/civic/2002/lx']) assert.ok(oldModelYear(p, 2005), p);
  for (const p of ['/cars/honda/civic/2005', '/cars/honda/civic', '/cars/honda', '/buy/used-cars/markham-on', '/t/car-detailing/honda/civic/2019/ex', '/rent-vs-own/honda/civic/2003',
    '/cars/honda-civic-2004-abc', '/car-rental/suv-rental/markham-on']) assert.equal(oldModelYear(p, 2005), false, p);
  assert.equal(oldModelYear('/cars/honda/civic/2004', 0), false, 'not known yet: never');
  assert.equal(vehiclePageYear('/t/car-detailing/honda/civic/2019/ex'), 2019);
  const r = oldYearGone();
  assert.equal(r.status, 404);
  assert.equal(r.headers.get('x-robots-tag'), 'noindex');
});
test('2402: province, territory and country pages follow their region (the /car-rental hub links, every place tree)', () => {
  const ontario = 1;
  for (const p of ['/car-rental/quebec', '/car-rental/british-columbia', '/car-rental/new-brunswick-nouveau-brunswick', '/car-rental/nunavut', '/car-rental/united-states',
    '/car-rental/mexico', '/fr/car-rental/quebec', '/car-rental/suv-rental/alberta', '/detailing/car-detailing/manitoba', '/body-shop/collision-repair/mexico',
    '/buy/used-cars/united-states', '/body-shop/collision-repair/villa-del-mar-ciudad-del-carmen-cam', '/buy/car-financing/austin-tx', '/buy/pre-owned-cars/houston-tx',
    '/buy/cash-for-cars/dallas-tx']) assert.ok(offMarketPlace(p, ontario), p);
  for (const p of ['/car-rental/ontario', '/car-rental/canada', '/car-rental/gta', '/car-rental/suv-rental/ontario', '/buy/toyota/mexico', '/car-rental/quebec-city-qc-extra/x/y'])
    assert.equal(offMarketPlace(p, ontario), false, p);
  assert.equal(offMarketPlace('/car-rental/quebec', ontario | (1 << CA_CODES.indexOf('qc'))), false, 'switched on: the app answers');
  assert.equal(offMarketPlace('/car-rental/united-states', ontario | (1 << MARKET_US_BIT)), false);
});
