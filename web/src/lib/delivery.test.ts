import { test } from 'node:test';
import assert from 'node:assert/strict';
import { deliveryArea, deliveryFrom } from './delivery.ts';

// Release 23: /delivery said "from $0 each way" (a car with no fee of its own) and named the service area.
test('delivery: never below the minimum; the delivery area text first', () => {
  assert.equal(deliveryFrom(0, 7500), 7500);
  assert.equal(deliveryFrom(12000, 7500), 12000);
  assert.equal(deliveryFrom(null, null), 0);
  assert.equal(deliveryArea({ delivery_area_text: 'All of Ontario', service_area: 'the GTA' }), 'All of Ontario');
  assert.equal(deliveryArea({ delivery_area_text: ' ', service_area: 'the GTA' }), 'the GTA');
});
