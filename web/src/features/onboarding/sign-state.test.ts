// The signature of a government form (r35, 1000): badges, who has something to sign, the summary lines.   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { needsSignature, signBadge, signSummary, signatureLine } from './sign-state.ts';

test('the badge of each state, in plain words', () => {
  assert.deepEqual(signBadge('signed'), { text: 'Signed', tone: 'ok' });
  assert.deepEqual(signBadge('ink'), { text: 'Signed in ink', tone: 'ok' });
  assert.deepEqual(signBadge('unsigned'), { text: 'Not signed', tone: 'todo' });
  assert.deepEqual(signBadge('changed'), { text: 'Changed since signed', tone: 'warn' });
  assert.equal(signBadge('unsigned', false)?.text, 'Waiting for a value');
  assert.equal(signBadge(null), null);
});

test('only a complete unsigned or changed form is waiting for the owner', () => {
  assert.equal(needsSignature('unsigned', true), true);
  assert.equal(needsSignature('changed', true), true);
  assert.equal(needsSignature('unsigned', false), false);
  assert.equal(needsSignature('signed', true), false);
  assert.equal(needsSignature('ink', true), false);
});

test('the summary line for the owner and for staff', () => {
  const two = [{ sign_state: 'unsigned' as const, signable: true }, { sign_state: 'signed' as const, signable: true }];
  assert.equal(signSummary(two, 'owner'), '1 of 2 forms to sign.');
  assert.equal(signSummary(two, 'staff'), '1 of 2 forms waiting for the owner\'s signature.');
  const changed = [{ sign_state: 'changed' as const, signable: true }];
  assert.match(signSummary(changed, 'owner'), /a form changed after you signed, so it needs your signature again/);
  assert.match(signSummary(changed, 'staff'), /1 changed since signed: the owner is asked to sign again/);
  assert.equal(signSummary([{ sign_state: 'signed' }, { sign_state: 'ink' }], 'owner'), 'You signed every form.');
  assert.equal(signSummary([], 'owner'), '');
});

test('the line beside the form says who signed, how and when, and whether the form changed', () => {
  const when = (iso: string) => iso.slice(0, 10);
  const s = { signer_name: 'Pat Example', method: 'drawn' as const, typed_name: null, signed_at: '2026-11-08T15:00:00Z', form_version: 1, current_version: 1, same_values: true, changed: [] };
  assert.equal(signatureLine(s, when), 'Pat Example signed with a drawn signature on 2026-11-08, version 1.');
  assert.match(signatureLine({ ...s, same_values: false, current_version: 2, changed: ['name_box'] }, when), /The form has changed since: this is version 2\. The owner is asked to sign again\./);
  assert.match(signatureLine({ ...s, method: 'typed' }, when), /typed name/);
});
