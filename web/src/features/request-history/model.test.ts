import { test } from 'node:test';
import assert from 'node:assert/strict';
import { lineWords, priceChange, revertHref, OWNER_TRIP } from './model.ts';

test('the owner trip badge says $0', () => { assert.equal(OWNER_TRIP, "Owner's own trip ($0)"); });
test('a line reads its description, else its type', () => {
  assert.equal(lineWords({ charge_type: 'delivery_fee', description: null, amount_cents: 1, hst_cents: 0 }), 'delivery fee');
  assert.equal(lineWords({ charge_type: 'x', description: 'Delivery', amount_cents: 1, hst_cents: 0 }), 'Delivery');
});
test('a price change is said only when the total moved', () => {
  const f = (c: number) => `$${(c / 100).toFixed(2)}`;
  assert.equal(priceChange(null, { total_cents: 1 }, f), null);
  assert.equal(priceChange({ total_cents: 100 }, { total_cents: 100 }, f), null);
  assert.equal(priceChange({ total_cents: 48000 }, { total_cents: 43000 }, f), 'Total $480.00 to $430.00');
});
test('revert opens the review with the version', () => { assert.equal(revertHref('/staff/bookings/B1', 2), '/staff/bookings/B1?tab=overview&revert=2#booking-review'); });
