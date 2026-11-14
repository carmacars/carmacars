import { test } from 'node:test';
import assert from 'node:assert/strict';
import { availQuery, availRange } from './availability.ts';

test('availability dates: tomorrow 10:00 for 3 days by default, in Toronto time', () => {
  const now = new Date('2026-11-13T03:30:00Z'); // still Nov 12 in Toronto
  assert.deepEqual(availRange({}, now), { af: '2026-11-13T10:00', at: '2026-11-16T10:00' });
});

test('availability dates: the address wins; a return before the pickup or a bad value is replaced', () => {
  assert.deepEqual(availRange({ af: '2026-12-01T09:30', at: '2026-12-05T18:00' }), { af: '2026-12-01T09:30', at: '2026-12-05T18:00' });
  assert.deepEqual(availRange({ af: '2026-12-01T09:30', at: '2026-11-30T09:30' }), { af: '2026-12-01T09:30', at: '2026-12-04T09:30' });
  assert.equal(availRange({ af: "2026-12-01'; drop", at: 'x' }, new Date('2026-11-13T15:00:00Z')).af, '2026-11-14T10:00');
});

test('availability query: Toronto times for the database; only known filters pass', () => {
  const q = availQuery({ af: '2026-12-01T09:30', at: '2026-12-05T18:00', ac: 'suv', as: '7', ap: '15000' });
  assert.deepEqual(q, { from: '2026-12-01 09:30 America/Toronto', to: '2026-12-05 18:00 America/Toronto', class: 'suv', seats_min: 7, max_daily_rate_cents: 15000 });
  assert.deepEqual(Object.keys(availQuery({ af: '2026-12-01T09:30', at: '2026-12-05T18:00', ac: 'tank', as: 'many', ap: '-1' })), ['from', 'to']);
});
