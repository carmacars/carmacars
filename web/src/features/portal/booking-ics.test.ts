import { test } from 'node:test';
import assert from 'node:assert/strict';
import { bookingIcs, icsOf } from './booking-ics.ts';

test('two events, escaped address, UTC times', () => {
  const s = bookingIcs({ number: 'CC-1', car: '2023 Audi Q5', pickup_at: '2026-11-05T15:00:00Z', return_at: '2026-11-08T15:00:00Z', pickup_place: '100 Queen St W, Toronto; Door 2' }, new Date('2026-11-01T00:00:00Z'));
  assert.equal(s.match(/BEGIN:VEVENT/g)?.length, 2);
  assert.match(s, /DTSTART:20261105T150000Z/);
  assert.match(s, /LOCATION:100 Queen St W\\, Toronto\\; Door 2/);
  assert.ok(s.includes('\r\n'));
});

test('Add to calendar escapes ; , and new lines in the location and text (r50 hotfix 2)', () => {
  const s = icsOf([{ uid: 'CC-2-pickup', title: 'Pick up, CC-2', start: '2026-11-05T15:00:00Z', minutes: 30, place: '100 Queen St W; Door 2', details: 'Line 1\nLine 2' }], '2026-11-01T00:00:00Z');
  assert.match(s, /LOCATION:100 Queen St W\\; Door 2\r\n/);
  assert.match(s, /SUMMARY:Pick up\\, CC-2/);
  assert.match(s, /DESCRIPTION:Line 1\\nLine 2/);
  assert.match(s, /TRIGGER:-PT2H/);
});
