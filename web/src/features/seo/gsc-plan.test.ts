import { test } from 'node:test';
import assert from 'node:assert/strict';
import { gscRow, isOurSitemap, locsOf, planSitemaps } from './gsc-plan.ts';

const B = 'https://carmacars.ca';
const head = [`${B}/sitemap.xml`, `${B}/sitemap-priority-1.xml`, `${B}/sitemap-priority-2.xml`, `${B}/sitemap-pages.xml`];
const files = Array.from({ length: 10 }, (_, i) => `${B}/sitemap-places-rental.car-rental.${i + 1}.xml`);

test('plan: the root index, the priority parts and site files first, then the files with addresses, up to the limit', () => {
  const p = planSitemaps({ base: B, head, files, current: [], max: 8, all: false });
  assert.deepEqual(p.desired, [...head, ...files.slice(0, 4)]);
  assert.deepEqual(p.submit, p.desired);
  assert.deepEqual(p.remove, []);
});

test('plan: the old index files (outside their directory) and the old priority file are removed; files already held are kept first', () => {
  const current = [
    { path: `${B}/sitemap.xml` }, { path: `${B}/sitemap-index/2.xml`, errors: 0 }, { path: `${B}/sitemap-index/480.xml` }, { path: `${B}/sitemap-priority.xml` },
    { path: files[9]!, errors: '1' }, { path: 'https://other.example/sitemap.xml' }, { path: `${B}/sitemap-vehicles/makes.xml` }
  ];
  const p = planSitemaps({ base: B, head, files, current, max: 6, all: false });
  assert.deepEqual(p.desired, [...head, files[9], files[0]]);
  assert.deepEqual(p.remove.sort(), [`${B}/sitemap-index/2.xml`, `${B}/sitemap-index/480.xml`, `${B}/sitemap-priority.xml`, `${B}/sitemap-vehicles/makes.xml`].sort());
  assert.ok(!p.remove.includes('https://other.example/sitemap.xml'), 'never another site\'s');
  assert.deepEqual(p.submit, [head[1], head[2], head[3], files[0]], 'only what the property lacks');
  assert.deepEqual(p.retry, [files[9]], 'the errored one again');
  assert.deepEqual(planSitemaps({ base: B, head, files, current, max: 6, all: true }).submit, p.desired, 'by hand: all of them again');
});

test('our sitemaps: current and old names on the site only', () => {
  for (const p of ['/sitemap.xml', '/sitemap-index-2.xml', '/sitemap-priority-1.xml', '/sitemap-vehicles-t-car-hire-toyota-years.xml', '/sitemap-places-rental.car-rental.3.xml', '/sitemap-index/7.xml', '/sitemap-vehicles/makes.xml'])
    assert.equal(isOurSitemap(B + p, B), true, p);
  for (const p of [`${B}/cars`, `${B}/feed.xml`, 'https://carmacars.ca.evil.example/sitemap.xml']) assert.equal(isOurSitemap(p, B), false, p);
});

test('a Search Console row: discovered addresses, errors, pending', () => {
  assert.deepEqual(gscRow({ path: `${B}/sitemap-priority-1.xml`, errors: '0', warnings: '2', isPending: false, lastDownloaded: '2026-10-23T10:00:00Z', contents: [{ type: 'web', submitted: '10000', indexed: '0' }] }),
    { path: `${B}/sitemap-priority-1.xml`, is_index: false, is_pending: false, last_submitted: null, last_downloaded: '2026-10-23T10:00:00Z', errors: 0, warnings: 2, submitted: 10000, indexed: 0 });
  assert.equal(gscRow({ path: `${B}/sitemap.xml`, isSitemapsIndex: true }).submitted, null);
  assert.deepEqual(locsOf('<sitemapindex><sitemap><loc>https://x/a.xml?x=1&amp;y=2</loc></sitemap></sitemapindex>'), ['https://x/a.xml?x=1&y=2']);
});
