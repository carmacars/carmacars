// r50 motion: the feedback words and the shake (src/portable/motion/feedback.ts). npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { doneWord, isRemoval, isSuccessText, SHAKE_MS } from './feedback.ts';

test('a finishing action gets its past tense; navigation and sign in never morph', () => {
  assert.equal(doneWord('Save'), 'Saved');
  assert.equal(doneWord('Save the rates'), 'Saved');
  assert.equal(doneWord('Send the offer'), 'Sent');
  assert.equal(doneWord('Sign'), 'Signed');
  assert.equal(doneWord('Pay $120.00'), 'Paid');
  assert.equal(doneWord('Approve'), 'Approved');
  assert.equal(doneWord('Copy the link'), 'Copied');
  assert.equal(doneWord('Put aside'), 'Done');
  for (const l of ['Next', 'Continue', 'Search', 'Sign in', 'Sign up', 'Back', '', null, undefined, 'Cancel']) assert.equal(doneWord(l), null, String(l));
});

test('a status that reports a finished thing is a success; a refusal is not', () => {
  for (const s of ['Saved.', 'Saved', 'Link copied', 'Done.', 'Sent', 'Refund sent.', 'Changes saved.']) assert.equal(isSuccessText(s), true, s);
  for (const s of ['Not saved.', 'Could not save.', 'Unsaved changes', 'Saving', 'Save?', '', 'Working']) assert.equal(isSuccessText(s), false, s);
});

test('the shake stays inside the 300 ms ceiling', () => { assert.ok(SHAKE_MS <= 300); });

test('one or two rows going is a removal; a list replaced is not', () => {
  assert.equal(isRemoval(1, 0), true);
  assert.equal(isRemoval(2, 0), true);
  assert.equal(isRemoval(3, 0), false);
  assert.equal(isRemoval(1, 1), false);
  assert.equal(isRemoval(0, 0), false);
});
