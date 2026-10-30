import { test } from 'node:test';
import assert from 'node:assert/strict';
import { checkDetails, detailFields, detailPayload, type RenterMissing } from './renter-details.ts';

const m = (field: string, key = `renter.${field}`): RenterMissing => ({ key, label: field, field });

test('the form asks exactly what is missing, once each, in order', () => {
  const f = detailFields([m('licence_expiry', 'drivers.d1.licence_expiry'), m('address'), m('card_last4', 'coverage.card_last4'), m('address')]);
  assert.deepEqual(f.map((x) => x.name), ['address', 'licence_expiry', 'card_last4']);
  assert.deepEqual(detailFields([]), []);
});

test('the checks before sending: required, a past date of birth, four digits, a full phone number', () => {
  const f = detailFields([m('date_of_birth'), m('address'), m('mobile'), m('card_last4', 'coverage.card_last4')]);
  const e = checkDetails(f, { date_of_birth: '2030-01-01', address_line1: '1 Queen St', city: '', province: 'ON', postal_code: 'M5H 2N2', mobile: '416555', card_last4: '12a4' }, '2026-10-30');
  assert.deepEqual(Object.keys(e).sort(), ['card_last4', 'city', 'date_of_birth', 'mobile']);
  assert.deepEqual(checkDetails(f, { date_of_birth: '1990-05-05', address_line1: '1 Queen St', city: 'Toronto', province: 'ON', postal_code: 'M5H 2N2', mobile: '416-555-0199', card_last4: '4242' }, '2026-10-30'), {});
});

test('only the asked fields are sent, trimmed; the licence number in capitals without spaces', () => {
  const f = detailFields([m('licence_number', 'drivers.d1.licence_number'), m('address')]);
  assert.deepEqual(detailPayload(f, { licence_number: ' a1234 12345 12345 ', address_line1: ' 1 Queen St ', city: 'Toronto', province: 'ON', postal_code: 'M5H 2N2', country: 'Canada', mobile: '416' }),
    { licence_number: 'A12341234512345', address_line1: '1 Queen St', city: 'Toronto', province: 'ON', postal_code: 'M5H 2N2', country: 'Canada' });
});
