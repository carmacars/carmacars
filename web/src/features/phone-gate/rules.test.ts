import { test } from 'node:test';
import assert from 'node:assert/strict';
import { draftPhone, formatAsTyped, gateNumber, gateOn, GATE_OFF, GATE_TEXT, passValid, passValue, photoLocked, PASS_DAYS, type GateRules } from './rules.ts';

// The phone number box (migration 0280): the number, the format as typed, the photos that need it, remembering a device.
const ON: GateRules = { ...GATE_OFF, gallery: true, dates: true, free_photos: 6 };
const VID = '0f8fad5b-d9cb-469f-a165-70867728950e';
const OTHER = '7c9e6679-7425-40de-944b-e07fc1f90ae7';

test('a Canadian or US mobile number, in any form; anything else refused', () => {
  assert.deepEqual(gateNumber('(647) 555-1234'), { ok: true, phone: '+16475551234', country: 'CA' });
  assert.deepEqual(gateNumber('1 416 555 0199'), { ok: true, phone: '+14165550199', country: 'CA' });
  assert.deepEqual(gateNumber('+1 212 555 0199'), { ok: true, phone: '+12125550199', country: 'US' });
  assert.equal(gateNumber('647 555 12').ok, false);
  assert.equal(gateNumber('').ok, false);
  assert.equal(gateNumber('+44 20 7946 0958').ok, false, 'not North American');
  assert.equal(gateNumber('876 555 1234').ok, false, 'Jamaica is +1 but not Canada or the US');
  assert.equal(gateNumber('800 555 1234').ok, false, 'toll-free');
});

test('formatted as it is typed', () => {
  assert.equal(formatAsTyped(''), '');
  assert.equal(formatAsTyped('6'), '(6');
  assert.equal(formatAsTyped('647'), '(647');
  assert.equal(formatAsTyped('6475'), '(647) 5');
  assert.equal(formatAsTyped('647555'), '(647) 555');
  assert.equal(formatAsTyped('6475551'), '(647) 555-1');
  assert.equal(formatAsTyped('6475551234'), '(647) 555-1234');
  assert.equal(formatAsTyped('16475551234'), '(647) 555-1234', 'a leading 1 is dropped');
  assert.equal(formatAsTyped('647-555-1234 ext 9'), '(647) 555-1234', 'at most 10 digits');
  assert.equal(formatAsTyped('(647) 555-1234'), '(647) 555-1234', 'formatting again changes nothing');
});

test('photos: the first 6 free, never on a car with 6 or fewer, nothing when the box is off', () => {
  assert.equal(photoLocked(5, 12, ON), false);
  assert.equal(photoLocked(6, 12, ON), true);
  assert.equal(photoLocked(11, 12, ON), true);
  assert.equal(photoLocked(5, 6, ON), false);
  assert.equal(photoLocked(3, 4, ON), false);
  assert.equal(photoLocked(6, 7, ON), true);
  assert.equal(photoLocked(8, 12, { ...ON, gallery: false }), false);
  assert.equal(photoLocked(2, 12, { ...ON, free_photos: 2 }), true);
  assert.equal(photoLocked(8, 12, null), false);
  assert.equal(gateOn(ON, 'dates'), true);
  assert.equal(gateOn(ON, 'request'), false);
  assert.equal(gateOn(undefined, 'dates'), false);
});

test('remembering a device: this visitor id, 90 days, no number in the cookie', () => {
  const now = Date.UTC(2026, 10, 1);
  const v = passValue(VID, now);
  assert.doesNotMatch(v, /\+1|555/, 'no phone number');
  assert.equal(passValid(v, VID, now), true);
  assert.equal(passValid(v, VID, now + (PASS_DAYS - 1) * 86400_000), true);
  assert.equal(passValid(v, VID, now + (PASS_DAYS + 1) * 86400_000), false, 'expired after 90 days');
  assert.equal(passValid(v, OTHER, now), false, 'another visitor id');
  assert.equal(passValid(v, null, now), false);
  assert.equal(passValid('garbage', VID, now), false);
  assert.equal(passValid(`${VID}.abc`, VID, now), false);
  assert.equal(passValid(undefined, VID, now), false);
});

test('a number already typed into the request form on this device counts', () => {
  assert.equal(draftPhone(JSON.stringify({ data: { phone: '647 555 1234' } })), '+16475551234');
  assert.equal(draftPhone(JSON.stringify({ data: { phone: '647' } })), null);
  assert.equal(draftPhone(JSON.stringify({ data: {} })), null);
  assert.equal(draftPhone('not json'), null);
  assert.equal(draftPhone(null), null);
});

test('the owner\'s words, with no long dashes', () => {
  assert.equal(GATE_TEXT.gallery, 'Put your phone number in to see more photos');
  assert.equal(GATE_TEXT.dates, 'Put your phone number in to see full availability');
  for (const t of Object.values(GATE_TEXT)) assert.doesNotMatch(t, /[\u2013\u2014]/);
});
