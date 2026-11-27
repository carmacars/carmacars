import { test } from 'node:test';
import assert from 'node:assert/strict';
import { OWNER_STAGES, RENTER_STAGES, ownerTrack, renterTrack } from './model.ts';

test('the renter demo: one stage to do now, the rest done or later', () => {
  for (let i = 0; i < RENTER_STAGES.length; i++) {
    const t = renterTrack(i);
    assert.ok(t.filter((s) => s.state === 'now').length <= 1, `stage ${i}`);
  }
  assert.deepEqual(renterTrack(0).map((s) => s.state), ['now', 'later', 'later', 'later', 'later', 'later']);
  assert.deepEqual(renterTrack(3).map((s) => s.state), ['done', 'done', 'now', 'later', 'later', 'later']);
  assert.ok(renterTrack(RENTER_STAGES.length - 1).every((s) => s.state === 'done'));
});

test('the owner demo: nine steps, listed at the end', () => {
  assert.equal(OWNER_STAGES.length, 9);
  assert.equal(ownerTrack(0)[0]!.state, 'now');
  assert.ok(ownerTrack(9).every((s) => s.state === 'done'));
});
