import { test } from 'node:test';
import assert from 'node:assert/strict';
import { approvableItems, approveLabel } from './doc-approve.ts';

test('Approve all names each item it approves', () => {
  const d = { uploads: [{ kind: 'licence_front', status: 'submitted' }, { kind: 'selfie', status: 'approved' }] };
  assert.equal(approveLabel(approvableItems(d, false, false)), 'Approve the licence front');
  assert.equal(approveLabel(approvableItems(d, true, true)), 'Approve all 3: licence front, proof of coverage and Protection Plan');
  assert.equal(approveLabel(approvableItems({ uploads: [] }, false, true)), 'Approve the Protection Plan');
  assert.deepEqual(approvableItems({ uploads: [] }, false, false), []);
});
