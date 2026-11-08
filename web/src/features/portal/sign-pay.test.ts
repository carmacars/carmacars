import { test } from 'node:test';
import assert from 'node:assert/strict';
import { signPayOf, signPayOpen, signPaySteps, signPayWords, type SignPay } from './sign-pay.ts';

// The one rule for signing and paying (0750), in words: what is left, the one button, two steps at most.
const s = (o: Partial<SignPay>): SignPay => signPayOf({ sign_pay: { step: 'sign', signed: false, stale: false, pay_after: true, due_cents: 123456, waiting: [], ...o } });

test('sign then pay: two steps, the amount in the sentence and on the button', () => {
  const w = signPayWords(s({}))!;
  assert.equal(w.title, 'Sign and pay');
  assert.equal(w.left, 'Two steps left: sign the rental agreement, then pay $1,234.56.');
  assert.equal(w.cta, 'Sign and pay $1,234.56');
  assert.deepEqual(signPaySteps(s({})).map((x) => `${x.label}:${x.state}`), ['Sign:now', 'Pay:next']);
});

test('signed for an older offer: sign the updated agreement, never sent to pay', () => {
  const w = signPayWords(s({ stale: true }))!;
  assert.match(w.left, /updated after you signed\. Sign the updated rental agreement, then pay \$1,234\.56\./);
});

test('signed: pay, one step left', () => {
  const w = signPayWords(s({ step: 'pay', signed: true }))!;
  assert.equal(w.left, 'One step left: pay $1,234.56. Your agreement is signed.');
  assert.equal(w.cta, 'Pay $1,234.56');
  assert.deepEqual(signPaySteps(s({ step: 'pay', signed: true })).map((x) => x.state), ['done', 'now']);
});

test('a driver still to sign is named', () => {
  assert.match(signPayWords(s({ step: 'drivers', waiting: ['Dana Driver'] }))!.left, /Dana Driver must sign the agreement too, then you pay/);
});

test('no payment after (a rental added by hand): sign only, one step', () => {
  const x = s({ pay_after: false, due_cents: 0 });
  assert.equal(signPayWords(x)!.left, 'One step left: sign the rental agreement.');
  assert.equal(signPaySteps(x).length, 1);
});

test('nothing left, or no rule on the read: no card', () => {
  assert.equal(signPayWords(s({ step: 'none' })), null);
  assert.equal(signPayOpen(signPayOf({})), false);
  assert.equal(signPayOf(null).step, 'none');
});
