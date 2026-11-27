import { test } from 'node:test';
import assert from 'node:assert/strict';
import { familiesOf, FIXED, pagePaths, SOFTWARE_PATH } from './sitemap-paths.ts';
import { TRACKER_PATHS } from '../trackers/pages.ts';

test('r50 hotfix 2: the tracker pages are in the pages file while the product is on, never twice across files', () => {
  const on = pagePaths({ trackers: true, careers: ['/careers'] });
  for (const p of ['/trackers', '/trackers/install', '/trackers/kill-switch-for-car', '/trackers/turo-host-gps-tracker', '/chauffeur', '/list-your-car', SOFTWARE_PATH]) assert.ok(on.includes(p), p);
  assert.equal(new Set(on).size, on.length, 'no address twice');
  const off = pagePaths({ trackers: false, careers: [] });
  assert.ok(!off.some((p) => p.startsWith('/trackers')), 'the product switched off: no tracker page listed');
  assert.ok(off.includes(SOFTWARE_PATH) && FIXED.every((p) => off.includes(p)));
  const fam = familiesOf([{ path: '/events', lastmod: null }, { path: '/trackers', lastmod: null }, { path: '/rent-vs-own', lastmod: null }], [{ slug: 'ajax' }]);
  assert.deepEqual(fam.map((r) => r.path), ['/events', '/rent-vs-own', '/trackers/install/ajax']);
  assert.ok(!fam.some((r) => TRACKER_PATHS.includes(r.path)));
});
