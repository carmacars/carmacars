import { test } from 'node:test';
import assert from 'node:assert/strict';
import { quickLinks } from './quick-links.ts';

const keys = (b: Parameters<typeof quickLinks>[0], lic: boolean) => quickLinks(b, lic).map((l) => l.key).join(',');

test('the licence from the request on, the coverage proof after approval', () => {
  assert.equal(keys({ booking_number: 'CC-1', status: 'requested' }, true), 'licence');
  assert.equal(keys({ booking_number: 'CC-1', status: 'offered' }, true), 'licence');
  assert.equal(keys({ booking_number: 'CC-1', status: 'offered' }, false), '');
  assert.equal(keys({ booking_number: 'CC-1', status: 'pending_payment', missing: ['identity', 'coverage'] }, true), 'licence,insurance,card_coverage');
  assert.equal(keys({ booking_number: 'CC-1', status: 'confirmed', missing: ['coverage'] }, false), 'insurance,card_coverage');
});

test('nothing once done or after the trip starts', () => {
  assert.equal(keys({ booking_number: 'CC-1', status: 'confirmed', missing: [], coverage_confirmed_at: '2026-11-01T00:00:00Z' }, false), '');
  assert.equal(keys({ booking_number: 'CC-1', status: 'on_rent', missing: ['coverage'] }, true), '');
  assert.equal(keys({ booking_number: 'CC-1', status: 'on_rent', added_mode: 'in_progress', missing: ['coverage'] }, false), 'insurance,card_coverage');
});

test('the links go to the verify page and the card checker', () => {
  const l = quickLinks({ booking_number: 'CC-10042', status: 'confirmed', missing: ['identity', 'coverage'] }, true);
  assert.deepEqual(l.map((x) => x.href), ['/account/bookings/CC-10042/verify', '/account/bookings/CC-10042/verify#pt-cov', '/credit-card-rental-coverage']);
});
