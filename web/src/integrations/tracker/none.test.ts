import { test } from 'node:test';
import assert from 'node:assert/strict';
import { noTracker } from './none.ts';

test('no tracker is connected: each command says so and returns no data', async () => {
  const t = noTracker();
  assert.equal(t.connected, false);
  const d = { vehicleId: 'v', deviceId: 'd' };
  for (const r of [await t.locate(d), await t.mileage(d), await t.requestImmobilize(d, { commandId: 'c', reason: 'test', requestedBy: 'u' })]) {
    assert.equal(r.ok, false);
    if (!r.ok) assert.equal(r.reason, 'not_connected');
  }
});
