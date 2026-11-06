import { test } from 'node:test';
import assert from 'node:assert/strict';
import { httpsRedirect, longTail, scraperGuard, tooMany, verifiedBot } from './scraper-guard.ts';

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
