import { test } from 'node:test';
import assert from 'node:assert/strict';
import { normalizePermit, permitScore, plateFormat, stickerDate, vinYear } from './permit-read.ts';

// A synthetic VIN with a valid check digit (no real car): 3FAKEPRM5RT000042, model year code R (2024).
const VIN = '3FAKEPRM5RT000042';
const TODAY = '2026-11-01';
const good = { plate: 'ABCD 123', vin: VIN, year: 2024, make: 'TESTM', model: 'TST', body: '4DR', colour: 'GRY', permit_number: 'X1234567', sticker_expiry: '271130', confidence: 90 };

test('a clean permit: every field read and checked, the sticker as a date, the colour as a swatch', () => {
  const r = normalizePermit(good, TODAY);
  assert.equal(r.vin, VIN);
  assert.equal(r.plate, 'ABCD123');
  assert.equal(r.year, 2024);
  assert.equal(r.colour, 'Grey');
  assert.equal(r.body_words, 'Sedan, 4 doors');
  assert.equal(r.permit_number, 'X1234567');
  assert.equal(r.sticker_expires_on, '2027-11-30');
  assert.deepEqual(r.problems, []);
  assert.deepEqual(permitScore(r), { ok: 9, of: 9 });
});

test('the VIN check digit: a misread character is flagged, not dropped', () => {
  const r = normalizePermit({ ...good, vin: '3FAKEPRM6RT000042' }, TODAY);
  assert.equal(r.checks.vin, 'check');
  assert.match(r.problems.join(' '), /check digit/);
  // O and I read for 0 and 1 are put right, then checked
  assert.equal(normalizePermit({ ...good, vin: '3FAKEPRM5RT0OOO42' }, TODAY).vin, VIN);
  assert.equal(normalizePermit({ ...good, vin: '3FAKEPRM5RT00004' }, TODAY).vin, null);
  assert.match(normalizePermit({ ...good, vin: null }, TODAY).problems.join(' '), /could not be read/);
});

test('the plate format: four letters and three digits, the older three and three, personalized flagged', () => {
  assert.equal(plateFormat('ABCD123'), 'standard');
  assert.equal(plateFormat('abc 123'), 'older');
  assert.equal(plateFormat('MYCAR'), 'personalized');
  assert.equal(plateFormat('123'), 'invalid');
  assert.equal(normalizePermit({ ...good, plate: 'MYCAR' }, TODAY).checks.plate, 'check');
  assert.equal(normalizePermit({ ...good, plate: '12-34' }, TODAY).plate, null);
});

test('the sticker expiry: YYMMDD, a real date only, an expired sticker flagged', () => {
  assert.equal(stickerDate('271231'), '2027-12-31');
  assert.equal(stickerDate('27/12/31'), '2027-12-31');
  assert.equal(stickerDate('2027-02-28'), '2027-02-28');
  assert.equal(stickerDate('270230'), null);
  assert.equal(stickerDate('1231'), null);
  const old = normalizePermit({ ...good, sticker_expiry: '260101' }, TODAY);
  assert.equal(old.checks.sticker_expires_on, 'check');
  assert.match(old.problems.join(' '), /expired/);
});

test('the year: from the VIN when the permit year is not read, a mismatch flagged', () => {
  assert.equal(vinYear(VIN), 2024);
  assert.equal(vinYear('3FAKEPRM5LT000042'), 2020);
  assert.equal(normalizePermit({ ...good, year: null }, TODAY).year, 2024);
  const r = normalizePermit({ ...good, year: 2019 }, TODAY);
  assert.equal(r.checks.year, 'check');
  assert.match(r.problems.join(' '), /VIN says 2024/);
});

test('nothing made up: an empty or broken answer reads as missing everywhere', () => {
  const r = normalizePermit('not json', TODAY);
  assert.equal(r.vin, null);
  assert.equal(r.plate, null);
  assert.equal(r.colour, null);
  assert.equal(permitScore(r).ok, 0);
  const n = normalizePermit({ ...good, colour: 'ZZZ', permit_number: '??' }, TODAY);
  assert.equal(n.colour, null);
  assert.equal(n.permit_number, null);
  assert.equal(n.checks.colour, 'check');
});
