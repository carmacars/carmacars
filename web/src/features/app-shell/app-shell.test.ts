import { test } from 'node:test';
import assert from 'node:assert/strict';
import { deletionStep } from './deletion.ts';
import { UNLOCK_AFTER_MS, lockDue } from './unlock.ts';

// The store app's profile parts (migration 0390): Delete my account's steps and when Face ID is asked again.
test('delete my account: ask, asked (with withdraw), done; hidden for an Admin', () => {
  const at = '2026-11-06T15:00:00Z';
  assert.equal(deletionStep({ allowed: true, request: null }), 'ask');
  assert.equal(deletionStep({ allowed: true, request: { status: 'open', requested_at: at, closed_at: null } }), 'asked');
  assert.equal(deletionStep({ allowed: true, request: { status: 'withdrawn', requested_at: at, closed_at: at } }), 'ask');
  assert.equal(deletionStep({ allowed: true, request: { status: 'done', requested_at: at, closed_at: at } }), 'done');
  assert.equal(deletionStep({ allowed: false, request: null }), 'hidden');
  assert.equal(deletionStep(null), 'hidden');
});

test('app lock: asked again after 5 minutes away, not before', () => {
  const t = 1_000_000_000;
  assert.equal(lockDue(t, t + UNLOCK_AFTER_MS - 1), false);
  assert.equal(lockDue(t, t + UNLOCK_AFTER_MS), true);
  assert.equal(lockDue(null, t), false);
});
