import { test } from 'node:test';
import assert from 'node:assert/strict';
import { SETTINGS_GROUPS, cardMatches, settingsSections } from './groups.ts';
import { SECTIONS } from '../../../app/admin/settings/sections.ts';

test('every settings page is in exactly one section, and no section names a page that does not exist', () => {
  const keys = SETTINGS_GROUPS.flatMap((g) => g.keys);
  assert.equal(keys.length, new Set(keys).size);
  assert.deepEqual([...keys].sort(), SECTIONS.map(([k]) => k).sort());
});

test('six sections, each with cards; the logs and phone alerts are on the page too', () => {
  const s = settingsSections(SECTIONS);
  assert.equal(s.length, 6);
  for (const g of s) assert.ok(g.cards.length > 0, g.id);
  const hrefs = s.flatMap((g) => g.cards.map((c) => c.href));
  for (const h of ['/admin/logs', '/admin/alerts', '/admin/settings/reviews', '/admin/settings/program']) assert.ok(hrefs.includes(h), h);
});

test('the search matches every word in the name or the description, any case', () => {
  const c = { href: '/x', title: 'Card reader', about: 'Pair the Stripe S700' };
  assert.ok(cardMatches(c, 'stripe'));
  assert.ok(cardMatches(c, '  CARD  s700 '));
  assert.ok(!cardMatches(c, 'card email'));
  assert.ok(cardMatches(c, ''));
});
