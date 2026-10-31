import { test } from 'node:test';
import assert from 'node:assert/strict';
import { bookingIcs } from './booking-ics.ts';

test('two events, escaped address, UTC times', () => {
  const s = bookingIcs({ number: 'CC-1', car: '2023 Audi Q5', pickup_at: '2026-11-05T15:00:00Z', return_at: '2026-11-08T15:00:00Z', pickup_place: '100 Queen St W, Toronto; Door 2' }, new Date('2026-11-01T00:00:00Z'));
  assert.equal(s.match(/BEGIN:VEVENT/g)?.length, 2);
  assert.match(s, /DTSTART:20261105T150000Z/);
  assert.match(s, /LOCATION:100 Queen St W\\, Toronto\\; Door 2/);
  assert.ok(s.includes('\r\n'));
});
