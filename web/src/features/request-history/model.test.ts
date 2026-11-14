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

test('a booking version says what it is (r45, 2861)', async () => {
  const { versionLabel, balanceWords } = await import('./model.ts');
  assert.equal(versionLabel({ no: 1, kind: 'start', restored: null, current: false }), 'Version 1, before the first change');
  assert.equal(versionLabel({ no: 5, kind: 'restore', restored: 1, current: true }), 'Version 5, version 1 restored (current)');
  const fmt = (c: number) => `$${(c / 100).toFixed(2)}`;
  assert.equal(balanceWords(0, 0, fmt), 'The balance does not change.');
  assert.match(balanceWords(1000, 3000, fmt), /owes \$20\.00 more/);
  assert.match(balanceWords(3000, 1000, fmt), /owed \$20\.00/);
  assert.equal(balanceWords(null, 1, fmt), '');
});
