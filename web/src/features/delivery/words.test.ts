import { test } from 'node:test';
import assert from 'node:assert/strict';
import { deliveryWords } from './words.ts';

test('a delivery leg in words (1403): included km, then the rate per km', () => {
  assert.equal(deliveryWords({ distance_km: 40, included_km: 15, per_km_cents: 200 }), '40 km from our location: first 15 km included, then $2.00 a km');
  assert.equal(deliveryWords({ distance_km: 9.96, included_km: 15, per_km_cents: 200 }), '10 km from our location, within the 15 km included');
  assert.equal(deliveryWords({ needs_distance: true, included_km: 15, per_km_cents: 200 }), 'Plus distance from our location beyond the first 15 km, priced in your offer');
  assert.equal(deliveryWords({ distance_km: 12 }), '12 km from our location');
  assert.equal(deliveryWords({}), undefined);
  assert.equal(deliveryWords(null), undefined);
});
