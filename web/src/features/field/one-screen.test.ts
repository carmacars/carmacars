import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mergeAnswers, prefill, sourceHint, stillNeeded, toEighths, type HandoverDefaults } from './one-screen.ts';

const d = (o: Partial<HandoverDefaults> = {}): HandoverDefaults => ({ odometer_km: 48210, odometer_from: 'tracker', fuel_pct: 74, fuel_from: 'tracker', keys_count: 2, keys_from: 'last_report', cleanliness: null, tracker_at: '2026-11-12T15:00:00Z', ...o });

test('the fuel is the nearest eighth, as the gauge reads', () => {
  assert.equal(toEighths(74), 75);
  assert.equal(toEighths(100), 100);
  assert.equal(toEighths(12), 13);
  assert.equal(toEighths(-4), 0);
  assert.equal(toEighths(140), 100);
});

test('a pickup starts with the odometer, the fuel and the keys that are known', () => {
  assert.deepEqual(prefill(d(), 'pickup', true), { odometer_km: 48210, fuel_pct: 75, keys_count: 2 });
  assert.deepEqual(prefill(null, 'pickup', true), {});
  assert.deepEqual(prefill(d({ odometer_km: null, fuel_pct: null, keys_count: null }), 'pickup', true), {});
});

test('a return also starts as standard cleanliness with the renter present; not present when the car was left', () => {
  assert.deepEqual(prefill(d({ odometer_km: null }), 'return', true), { fuel_pct: 75, keys_count: 2, cleanliness: 'clean', renter_present: true });
  assert.equal(prefill(d(), 'return', false).renter_present, undefined);
});

test('what the server has wins over the prefill, and a missing value never hides a filled one', () => {
  assert.deepEqual(mergeAnswers<{ odometer_km?: number; fuel_pct?: number; notes?: string }>({ odometer_km: 100, fuel_pct: 75 }, { odometer_km: 140, fuel_pct: undefined, notes: '' }), { odometer_km: 140, fuel_pct: 75 });
  assert.deepEqual(mergeAnswers({ a: 1 }, null, undefined), { a: 1 });
});

test('a prefilled field says where it came from until staff change it', () => {
  assert.match(sourceHint('odometer', d(), 48210) ?? '', /from the Tracker/);
  assert.equal(sourceHint('odometer', d(), 48300), null);
  assert.match(sourceHint('odometer', d({ odometer_from: 'last_report' }), 48210) ?? '', /last report/);
  assert.match(sourceHint('fuel', d({ fuel_pct: 100, fuel_from: 'full' }), 100) ?? '', /Set to full/);
  assert.match(sourceHint('fuel', d({ fuel_pct: 50, fuel_from: 'pickup' }), 50) ?? '', /level at pickup/);
  assert.equal(sourceHint('fuel', d(), 50), null);
  assert.match(sourceHint('keys', d({ keys_from: 'pickup' }), 2) ?? '', /handed over at pickup/);
  assert.equal(sourceHint('keys', d({ keys_count: 1, keys_from: 'one' }), 1), null);
  assert.equal(sourceHint('odometer', null, 5), null);
});

test('what is still needed: in the order of the screen, never an optional part', () => {
  const parts = [{ id: 'ready', title: 'Ready check', ok: true }, { id: 'readings', title: 'Readings', ok: false, need: 'Odometer' },
    { id: 'notes', title: 'Notes', ok: false, optional: true }, { id: 'sign', title: 'Review and sign', ok: false }];
  assert.deepEqual(stillNeeded(parts), [{ id: 'readings', label: 'Odometer' }, { id: 'sign', label: 'Review and sign' }]);
  assert.deepEqual(stillNeeded(parts.map((p) => ({ ...p, ok: true }))), []);
});
