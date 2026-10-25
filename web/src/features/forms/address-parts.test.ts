import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fromComponents, fromLabel, siblingFill, toLine } from './address-parts.ts';

test('Google components fill each part, the postal code with its space', () => {
  const p = fromComponents([
    { longText: '65', types: ['street_number'] }, { longText: 'Front Street West', shortText: 'Front St W', types: ['route'] },
    { longText: '4', types: ['subpremise'] }, { longText: 'Toronto', types: ['locality', 'political'] },
    { longText: 'Ontario', shortText: 'ON', types: ['administrative_area_level_1'] }, { longText: 'M5J1E6', types: ['postal_code'] },
    { longText: 'Canada', shortText: 'CA', types: ['country'] }]);
  assert.deepEqual(p, { street: '65 Front Street West', unit: '4', city: 'Toronto', province: 'ON', postal_code: 'M5J 1E6', country: 'Canada' });
});

test('no components: nothing to fill from them', () => {
  assert.equal(fromComponents([]), null);
  assert.equal(fromComponents(undefined), null);
});

test('a one-line Canadian address is split', () => {
  assert.deepEqual(fromLabel('65 Front St W, Unit 4, Toronto, ON M5J 1E6, Canada'), { street: '65 Front St W', unit: '4', city: 'Toronto', province: 'ON', postal_code: 'M5J 1E6', country: 'Canada' });
  assert.deepEqual(fromLabel('Union Station, 65 Front Street West, Toronto, ON'), { street: '65 Front Street West', unit: '', city: 'Toronto', province: 'ON', postal_code: '', country: 'Canada' });
});

test('a US address keeps its ZIP code and country', () => {
  const p = fromLabel('1 Main St, Buffalo, NY 14202, USA');
  assert.equal(p.city, 'Buffalo'); assert.equal(p.province, 'NY'); assert.equal(p.postal_code, '14202'); assert.equal(p.country, 'United States');
});

test('back to one line', () => {
  assert.equal(toLine({ street: '65 Front St W', unit: '4', city: 'Toronto', province: 'ON', postal_code: 'M5J 1E6', country: 'Canada' }), '65 Front St W, Unit 4, Toronto, ON M5J 1E6');
});

test('a form of named fields: the address field\'s siblings are filled (2026-10-24)', () => {
  const p = { street: '65 Front St W', unit: '4', city: 'Toronto', province: 'ON', postal_code: 'M5J 1E6', country: 'Canada' };
  const label = '65 Front St W, Unit 4, Toronto, ON M5J 1E6, Canada';
  // the business address in Site settings, with its coordinates
  assert.deepEqual(siblingFill('business_street', ['business_name', 'business_street', 'business_city', 'business_region', 'business_postal_code', 'business_latitude', 'business_longitude'], p, label, { lat: 43.6, lng: -79.3 }),
    { business_street: '65 Front St W, Unit 4', business_city: 'Toronto', business_region: 'ON', business_postal_code: 'M5J 1E6', business_latitude: '43.6', business_longitude: '-79.3' });
  // a partner: street, city and postal code
  assert.deepEqual(siblingFill('address_line1', ['business_name', 'address_line1', 'city', 'postal_code'], p, label), { address_line1: '65 Front St W, Unit 4', city: 'Toronto', postal_code: 'M5J 1E6' });
  // a staff member's home address and postal code: the address stays on one line
  assert.deepEqual(siblingFill('home_address', ['home_address', 'home_postal_code'], p, label), { home_address: label, home_postal_code: 'M5J 1E6' });
  // the delivery origin: one line and its coordinates
  assert.deepEqual(siblingFill('company_address', ['company_latitude', 'company_longitude', 'company_address'], p, label, { lat: 1, lng: 2 }), { company_address: label, company_latitude: '1', company_longitude: '2' });
  // alone in its form
  assert.deepEqual(siblingFill('place', ['place', 'odometer'], p, label), { place: label });
});
