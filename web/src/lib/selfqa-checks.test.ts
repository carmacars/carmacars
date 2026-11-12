// Unit tests for the deploy's self-check (web/scripts/selfqa-checks.mjs, used by web/scripts/verify-live.mjs --selfqa; 2400).
//   node --test --experimental-strip-types src/lib/selfqa-checks.test.ts   (npm run test:unit)
import { test } from 'node:test';
import assert from 'node:assert/strict';
// @ts-expect-error the checks are plain JavaScript (the script runs without a build)
import { letteringOverflow, noindex, serverFailure, sitemapLocs, standinSlugs, standinUrls } from '../../scripts/selfqa-checks.mjs';
import { standInSvg } from '../features/car/studio.ts';

test('a 5xx or Cloudflare\'s Error 1101 is a failure; a 404 or a redirect is not', () => {
  assert.equal(serverFailure(503, ''), 'answered 503');
  assert.match(serverFailure(200, '<h1>Error 1101</h1> Worker threw exception') ?? '', /1101/);
  assert.equal(serverFailure(404, 'Not found'), null);
  assert.equal(serverFailure(307, ''), null);
  assert.equal(serverFailure(200, '<html>ok</html>'), null);
});

test('the cars on a stand-in are found by their card (also through the image service\'s encoded address)', () => {
  const html = '<a href="/cars/toyota-camry-2022-a1"><img src="/_next/image?url=%2Fsample-photos%2Fstudio%2Fsedan%2Fblack%2Flead%2FCAMRY.svg&w=640"></a>'
    + '<a href="/cars/toyota-camry-2022-a1">Camry</a>'
    + '<a href="/cars/honda-civic-2021-b2"><img src="https://photos.example.test/vehicles/x/civic-800.jpg"></a>';
  assert.deepEqual(standinSlugs(html), ['toyota-camry-2022-a1']);
  assert.deepEqual(standinUrls(html), ['/sample-photos/studio/sedan/black/lead/CAMRY.svg']);
});

test('the stand-in lettering of the site fits its wall; a line off the panel or squeezed is reported', () => {
  for (const name of ['C-CLASS', 'GRAND CHEROKEE L SUMMIT', 'MODEL Y', 'F-150 LIGHTNING PLATINUM X']) {
    assert.deepEqual(letteringOverflow(standInSvg({ shape: 'sedan', paint: 'black', shot: 'lead', name })), [], name);
  }
  const wide = '<text x="900" y="450" text-anchor="middle" font-size="150" textLength="1300">VERY LONG NAME</text>';
  assert.match(letteringOverflow(wide)[0] ?? '', /runs off the wall panel/);
  const squeezed = '<text x="900" y="450" text-anchor="middle" font-size="150" textLength="400">VERY LONG NAME HERE</text>';
  assert.match(letteringOverflow(squeezed)[0] ?? '', /squeezed/);
  assert.deepEqual(letteringOverflow('<text x="1755" y="1164" text-anchor="end">REPRESENTATIVE PHOTO</text>'), [], 'the slate is not the lettering');
});

test('noindex is read from the robots meta tag or the X-Robots-Tag header', () => {
  assert.equal(noindex('<meta name="robots" content="noindex, follow">', new Headers()), true);
  assert.equal(noindex('<meta content="noindex" name="googlebot">', new Headers()), true);
  assert.equal(noindex('<meta name="robots" content="index, follow">', new Headers()), false);
  assert.equal(noindex('<p>noindex</p>', new Headers({ 'x-robots-tag': 'noindex' })), true);
  assert.equal(noindex('<meta name="description" content="noindex is a word">', new Headers()), false);
});

test('a sitemap\'s addresses and whether it is an index', () => {
  assert.deepEqual(sitemapLocs('<sitemapindex><sitemap><loc>https://carmacars.ca/sitemap-cars.xml</loc></sitemap></sitemapindex>'),
    { index: true, locs: ['https://carmacars.ca/sitemap-cars.xml'] });
  assert.deepEqual(sitemapLocs('<urlset></urlset>'), { index: false, locs: [] });
  assert.deepEqual(sitemapLocs('<urlset><url><loc> https://carmacars.ca/cars?a=1&amp;b=2 </loc></url></urlset>').locs, ['https://carmacars.ca/cars?a=1&b=2']);
});
