import { test } from 'node:test';
import assert from 'node:assert/strict';
import { availRs, errorRs, parseAvailRq } from './ota.ts';

const RQ = '<?xml version="1.0"?><OTA_VehAvailRateRQ xmlns="http://www.opentravel.org/OTA/2003/05" EchoToken="abc" Version="1.0"><VehAvailRQCore Status="Available"><VehRentalCore PickUpDateTime="2031-03-02T10:00:00" ReturnDateTime="2031-03-04T10:00:00"><PickUpLocation LocationCode="BASE"/></VehRentalCore></VehAvailRQCore></OTA_VehAvailRateRQ>';

test('the request: pickup, return and the echo token', () => {
  assert.deepEqual(parseAvailRq(RQ), { pickupAt: '2031-03-02T10:00:00', returnAt: '2031-03-04T10:00:00', echoToken: 'abc' });
  assert.equal(parseAvailRq('<OTA_VehAvailRateRQ><VehRentalCore PickUpDateTime="x" ReturnDateTime="y"/></OTA_VehAvailRateRQ>'), null);
  assert.equal(parseAvailRq('<Other/>'), null);
  // no entities or DOCTYPE (XXE)
  assert.equal(parseAvailRq('<!DOCTYPE x [<!ENTITY e SYSTEM "file:///etc/passwd">]>' + RQ), null);
});

test('the answer lists the cars that can be booked, with totals, escaped', () => {
  const xml = availRs(parseAvailRq(RQ)!, [
    { ref: 'car-1', available: true, currency: 'CAD', total_cents: 24860, rental_cents: 22000, billable_days: 2, km_per_day: 200, deposit_cents: 100000 },
    { ref: 'car-2', available: false, currency: 'CAD', total_cents: 1, rental_cents: 1, billable_days: 2, km_per_day: 200, deposit_cents: null }
  ], new Map([['car-1', { ref: 'car-1', class: 'suv', make: 'A&B', model: 'X<1>', year: 2024, seats: 5, transmission: 'Automatic', photos: [] }]]), new Date('2031-01-01T00:00:00Z'));
  assert.match(xml, /EchoToken="abc"/);
  assert.match(xml, /EstimatedTotalAmount="248.60"/);
  assert.match(xml, /UnitCharge="110.00" UnitName="Day" Quantity="2"/);
  assert.match(xml, /Name="2024 A&amp;B X&lt;1&gt;"/);
  assert.doesNotMatch(xml, /car-2/);
  assert.match(errorRs('Bad <key>'), /Bad &lt;key&gt;/);
});
