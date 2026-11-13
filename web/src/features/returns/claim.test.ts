import { test } from 'node:test';
import assert from 'node:assert/strict';
import { claimPayload, claimPhotoKey, fuelLabel, MAX_PHOTOS, MAX_PICKED_PHOTOS, reportNote } from './claim.ts';

const now = new Date('2026-11-06T15:00:00Z');

test('everything is optional: an empty form is a valid report', () => {
  const r = claimPayload({}, now);
  assert.deepEqual(r, { ok: true, payload: { photos: [] } });
});

test('the readings and the time become the database payload', () => {
  const r = claimPayload({ returned_at: '2026-11-06T14:30:00Z', odometer_km: '12 345', fuel_pct: '75', note: '  Keys in the box ', photos: [{ bucket: 'condition-photos', path: 'x' }] }, now);
  assert.ok(r.ok);
  assert.deepEqual(r.payload, { returned_at: '2026-11-06T14:30:00.000Z', odometer_km: 12345, fuel_pct: 75, note: 'Keys in the box', photos: [{ bucket: 'condition-photos', path: 'x' }] });
});

test('a future time, a bad odometer, an unknown fuel level or too many photos are refused in words', () => {
  assert.equal(claimPayload({ returned_at: '2026-11-06T16:00:00Z' }, now).ok, false);
  assert.equal(claimPayload({ odometer_km: '12.5' }, now).ok, false);
  assert.equal(claimPayload({ odometer_km: '-3' }, now).ok, false);
  assert.equal(claimPayload({ fuel_pct: '60' }, now).ok, false);
  const many = Array.from({ length: MAX_PHOTOS + 1 }, (_, i) => ({ bucket: 'condition-photos', path: String(i) }));
  const r = claimPayload({ photos: many }, now);
  assert.equal(r.ok, false);
});

test('photo keys sit under the booking, as the database checks', () => {
  assert.equal(claimPhotoKey('b1', '9d3b6a1e-4c2f-4b7a-8e1d-2f6c5a4b3e21', false), 'bookings/b1/return-claim/9d3b6a1e-4c2f-4b7a-8e1d-2f6c5a4b3e21.jpg');
  assert.equal(claimPhotoKey('b1', 'x', true), 'bookings/b1/return-claim/x.png');
});

test('fuel labels', () => {
  assert.equal(fuelLabel(100), 'Full');
  assert.equal(fuelLabel(25), '1/4');
  assert.equal(fuelLabel(60), '60%');
  assert.equal(fuelLabel(null), 'not given');
});

test('a report with a missing reading is still sent: the note says staff will confirm, and the photo cap leaves room for the reading photos', () => {
  assert.match(reportNote('Take the selfie in front of the car with the camera.'), /send the report anyway/);
  assert.match(reportNote('Take the selfie in front of the car with the camera.'), /take the selfie/i);
  assert.match(reportNote(null), /completed at once/);
  assert.equal(MAX_PICKED_PHOTOS + 2, MAX_PHOTOS);
  assert.ok(claimPayload({ photos: Array.from({ length: MAX_PHOTOS }, (_, i) => ({ bucket: 'condition-photos', path: String(i) })) }, now).ok);
});
