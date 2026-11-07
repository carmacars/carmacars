import { test } from 'node:test';
import assert from 'node:assert/strict';
import { BOOKING_SECTIONS, OLD_TAB, bookingSection, shows } from './sections.ts';

test('r32: the booking page has six sections and every old tab lands in one of them', () => {
  assert.equal(BOOKING_SECTIONS.length, 6);
  const keys = new Set(BOOKING_SECTIONS.map(([k]) => k));
  for (const t of ['review', 'overview', 'money', 'changes', 'messages', 'history', 'documents']) assert.ok(keys.has(OLD_TAB[t]!), t);
  assert.equal(bookingSection(undefined), 'overview');
  assert.equal(bookingSection('nonsense'), 'overview');
  assert.equal(bookingSection('changes'), 'extras');
  assert.equal(bookingSection('history'), 'activity');
});

test('r32: the overview is the review while an offer is arranged; messages and history share a section', () => {
  assert.equal(shows('overview', 'review', true), true);
  assert.equal(shows('overview', 'overview', true), false);
  assert.equal(shows('overview', 'overview', false), true);
  assert.equal(shows('activity', 'messages', false), true);
  assert.equal(shows('activity', 'history', false), true);
  assert.equal(shows('money', 'history', false), false);
});
