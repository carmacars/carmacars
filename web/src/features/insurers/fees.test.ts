// The charges to the insurer (migration 0180): the rates typed as the database takes them.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { INSURER_FEES, feeForDays, insurerFeesPayload, insurerFeesRemoval, isInsurerFee, rateCents, rateProblem, typedFrom } from './fees.ts';

test('the five charges, in the order of the form, with their Blind Spot boxes', () => {
  assert.deepEqual(INSURER_FEES.map((f) => `${f.code}:${f.box}`), ['vlf:43', 'ldw:45', 'tldw:46', 'pap_pec:47', 'waiver_saver:Waiver Saver']);
  assert.ok(isInsurerFee('pap_pec') && !isInsurerFee('winter_tire') && !isInsurerFee(null));
});

test('a rate typed in dollars, in cents; anything else is a problem said under the box', () => {
  assert.equal(rateCents('12.5'), 1250);
  assert.equal(rateCents('$1,200'), 120000);
  assert.equal(rateCents(''), null);
  assert.equal(rateCents('12.345'), null);
  assert.equal(rateProblem('abc'), 'Type the rate a day in dollars and cents, for example 12.50.');
  assert.equal(rateProblem(''), null);
});

test('only what changed is sent; emptied or 0 is removed; a box that is not a number is left out', () => {
  assert.deepEqual(insurerFeesPayload({ vlf: '5', ldw: '', tldw: '0', pap_pec: 'x', waiver_saver: '3.00' }, { ldw: 1500, waiver_saver: 300, pap_pec: 700 }),
    { vlf: 500, ldw: null });
  assert.deepEqual(insurerFeesRemoval({ vlf: 500, ldw: 1500 }), { vlf: null, ldw: null });
  assert.deepEqual(typedFrom({ vlf: 500, delivery: 100 }), { vlf: '5.00' });
});

test('the rate times the days, under the box', () => {
  const m = (c: number) => `$${(c / 100).toFixed(2)}`;
  assert.equal(feeForDays(500, 3, m), '= $15.00 for 3 days');
  assert.equal(feeForDays(500, 1, m), '= $5.00 for 1 day');
  assert.equal(feeForDays(null, 3, m), '');
});
