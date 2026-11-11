import { test } from 'node:test';
import assert from 'node:assert/strict';
import { identityMode } from './identity.ts';

test('a renter edits the name and date of birth until a licence is verified, then asks for a correction', () => {
  assert.equal(identityMode({ identity_locked: false, pending: null }), 'edit');
  assert.equal(identityMode({ identity_locked: true, pending: null }), 'request');
  assert.equal(identityMode({ identity_locked: true, pending: { requested_name: 'X' } }), 'pending');
});
