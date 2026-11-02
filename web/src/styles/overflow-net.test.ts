// The phone safety net (r27 leftovers, docs/changes/2026-11-07-r27-leftovers.md section 7): html and body clip what passes
// the right edge, pinch-zoom stays allowed, and both overflow checks lift the net while measuring (any overflow over 0px fails).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const read = (p: string) => readFileSync(new URL(p, import.meta.url), 'utf8');

test('html, body { overflow-x: clip } in the shared stylesheet the public site loads', () => {
  assert.match(read('./core.css'), /html, body \{ overflow-x: clip; \}/);
});
test('pinch-zoom allowed: the viewport sets no maximum scale and never turns zoom off', () => {
  const layout = read('../app/layout.tsx');
  const vp = /export const viewport: Viewport = \{([^}]*)\}/.exec(layout)?.[1] ?? '';
  assert.ok(vp.includes("width: 'device-width'"), vp);
  assert.doesNotMatch(vp, /maximumScale|userScalable/);
  assert.doesNotMatch(layout, /user-scalable=no|maximum-scale=1/);
});
test('the crawl fails on any overflow over 0px at 375 (every role, menus, chat, date sheet, phone box, game) and the public site at 390', () => {
  const crawl = read('../../tests/lint/crawl-roles.mjs');
  assert.match(crawl, /overflow-x: visible !important/);
  assert.match(crawl, /if \(over <= 0\) return null;/);
  assert.match(crawl, /\[375, 812\], \.\.\.\(role === 'anon' \? \[\[390, 844\]\] : \[\]\)/);
  assert.match(crawl, /overlayOverflow\(page\)/);
  assert.match(crawl, /getByTestId\('chat-open'\)/);
  assert.match(crawl, /phone number box open/);
  assert.match(crawl, /\?preview=game/);
  const helpers = read('../../tests/e2e/helpers.ts');
  assert.match(helpers, /overflow-x: visible !important/);
  assert.match(helpers, /toBeLessThanOrEqual\(0\)/);
});
