import { test } from 'node:test';
import assert from 'node:assert/strict';
import { clock, fromNow, maps, tel } from './format.ts';

test('clock: the hour and minute in Toronto, with a.m. or p.m.', () => {
  assert.deepEqual(clock('2026-10-25T18:30:00Z'), { time: '2:30', half: 'p.m.' }); // EDT, UTC-4
  assert.deepEqual(clock('2026-12-01T14:05:00Z'), { time: '9:05', half: 'a.m.' }); // EST, UTC-5
});

test('fromNow: minutes and hours ahead or behind, and now', () => {
  const now = '2026-10-25T12:00:00Z';
  assert.deepEqual(fromNow('2026-10-25T12:25:00Z', now), { text: 'in 25 min', late: false });
  assert.deepEqual(fromNow('2026-10-25T14:10:00Z', now), { text: 'in 2 h 10 min', late: false });
  assert.deepEqual(fromNow('2026-10-25T13:00:00Z', now), { text: 'in 1 h', late: false });
  assert.deepEqual(fromNow('2026-10-25T12:01:00Z', now), { text: 'now', late: false });
  assert.deepEqual(fromNow('2026-10-25T11:20:00Z', now), { text: '40 min ago', late: true });
});

test('maps and tel links', () => {
  assert.equal(maps('1 Front St W, Toronto'), 'https://www.google.com/maps/search/?api=1&query=1%20Front%20St%20W%2C%20Toronto');
  assert.equal(tel('(416) 555-0142'), 'tel:4165550142');
});
