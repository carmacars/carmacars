// r44 (2812): an agreement an Admin makes for a rental that has already ended (an insurer's file needs it signed) prints a
// detail that is not on file as a blank, never "To be given before pickup". Made-up facts only.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { agreementBlocks } from './model.ts';
import { richFacts } from './rich-fixture.ts';

const text = (after: boolean) => {
  const { f, x, bs } = richFacts('open');
  f.booking = { ...f.booking, after_trip: after };
  f.renter = f.renter ? { ...f.renter, date_of_birth: null, mobile: null } : f.renter;
  f.drivers = f.drivers.map((d) => ({ ...d, date_of_birth: null, licence_expiry: null }));
  return JSON.stringify(agreementBlocks(f, { privacyUrl: 'https://example.test/privacy', extra: x, insurer: bs.insurer }));
};

test('before the trip a missing detail says it is to be given before pickup', () => {
  assert.match(text(false), /To be given before pickup/);
});

test('after the trip a missing detail is blank', () => {
  const t = text(true);
  assert.doesNotMatch(t, /To be given before pickup/);
  assert.doesNotMatch(t, /MISSING/i);
  assert.match(t, /Date of birth: {2}/);
});
