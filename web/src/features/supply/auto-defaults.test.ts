import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { autoCardFields, autoSource } from './auto-defaults.ts';

describe('values set automatically (0087)', () => {
  it('a value is marked while it is the automatic one', () => {
    const auto = { fleet_number: { value: 'CC 101', source: 'The next fleet number (Program settings)' } };
    assert.equal(autoSource(auto, 'fleet_number', 'CC 101'), 'The next fleet number (Program settings)');
    assert.equal(autoSource(auto, 'fleet_number', 'CC 7'), null);
    assert.equal(autoSource({}, 'fleet_number', 'CC 101'), null);
    assert.equal(autoSource(null, 'allows_18_to_20', true), null);
  });
  it('the rate card lists only the values still at their default', () => {
    const card = { daily_rate_cents: 6900, deposit_cents: 60000, delivery_fee_cents: 7500,
      auto_defaults: { daily: { value: 6900, source: 'suggested' }, deposit: { value: 50000, source: 'class' }, delivery: { value: 7500, source: 'class' } } };
    assert.deepEqual(autoCardFields(card).map((f) => f.key), ['daily', 'delivery']);
    assert.deepEqual(autoCardFields(null), []);
  });
});
