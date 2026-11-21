import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fallbackVision } from './fake.ts';

const req = { system: 's', prompt: 'p', imageDataUrl: 'data:image/jpeg;base64,AA', maxOutputTokens: 10 };

test('with no vision model connected, the live site reads nothing (never the fake\'s invented answer)', async () => {
  for (const purpose of ['licence_read', 'toll_read', 'vin_read', 'permit_read'] as const) {
    const r = await fallbackVision(true).read({ ...req, purpose }, []);
    assert.equal(r.ok, false, purpose);
    assert.equal(r.ok ? '' : r.reason, 'unavailable');
  }
});

test('locally and in the tests the fake still answers', async () => {
  assert.equal((await fallbackVision(false).read({ ...req, purpose: 'colour_read' }, [])).ok, true);
});
