import { test } from 'node:test';
import assert from 'node:assert/strict';
import { nextStep, type NextStepInput } from './next-step.ts';

// The "Next step" panel of a booking (2026-10-30): one sentence and at most one button, for each status.
const base = '/admin/bookings/CC-1';
const now = new Date('2026-10-30T14:00:00Z'); // 10:00 Toronto
const x = (o: Partial<NextStepInput>): NextStepInput => ({ status: 'requested', base, now, pickupAt: '2026-11-05T14:00:00Z', returnAt: '2026-11-08T14:00:00Z', ...o });

test('requested: send the offer, a button to the review tab; it says it is booked once the renter approves (0540)', () => {
  const s = nextStep(x({}));
  assert.equal(s.step, 'send_offer');
  assert.match(s.text, /booked once the renter approves/);
  assert.deepEqual(s.action, { label: 'Send the offer', href: `${base}?tab=review`, testId: 'next-step-offer' });
  assert.equal(nextStep(x({ can: { offer: false } })).action, undefined);
});

test('offered: waiting for the renter, until when; no button', () => {
  const s = nextStep(x({ status: 'offered', offerExpiresAt: '2026-10-31T14:00:00Z' }));
  assert.equal(s.step, 'wait_offer');
  assert.equal(s.who, 'The renter');
  assert.match(s.text, /^Waiting for the renter to approve the offer \(open until Sat, Oct 31, 10:00/);
  assert.equal(s.action, undefined);
});

test('pending_payment: the amount open, record or send a pay link (Money tab)', () => {
  const s = nextStep(x({ status: 'pending_payment', dueCents: 123456, paidCents: 23456 }));
  assert.equal(s.step, 'wait_payment');
  assert.match(s.text, /Booked: the renter approved the offer\. Payment due: \$1,000\.00 open\. Record cash or e-Transfer, or send a pay link\./);
  assert.equal(s.action?.href, `${base}?tab=money`);
  assert.doesNotMatch(nextStep(x({ status: 'pending_payment', dueCents: 100, paidCents: 100 })).text, /open/);
});

test('r33: pending_payment states what the renter sees (the one rule, 0750)', () => {
  const left = 'Two steps left: sign the rental agreement, then pay $1,000.00.';
  const s = nextStep(x({ status: 'pending_payment', dueCents: 100000, renterStep: 'sign', renterLeft: left }));
  assert.match(s.text, /still has to sign, then pay \$1,000\.00\. The renter sees: "Two steps left: sign the rental agreement, then pay \$1,000\.00\."/);
  assert.equal(s.action?.testId, 'next-step-sign');
  const p = nextStep(x({ status: 'pending_payment', dueCents: 100000, renterStep: 'pay', renterLeft: 'One step left: pay $1,000.00. Your agreement is signed.' }));
  assert.match(p.text, /approved the offer and signed\. Payment due: \$1,000\.00 open\. The renter sees: "One step left: pay/);
  assert.equal(p.essentials?.find((e) => e.key === 'agreement')?.done, true);
  assert.equal(s.essentials?.find((e) => e.key === 'agreement')?.done, false);
});

test('confirmed, agreement not signed: the renter signs (on this device)', () => {
  const s = nextStep(x({ status: 'confirmed', awaitingSignature: true, depositCents: 50000 }));
  assert.equal(s.step, 'sign');
  assert.deepEqual(s.action, { label: 'Sign on this device', href: `${base}/sign-now`, testId: 'next-step-sign' });
});

test('confirmed, signed, deposit not held, pickup ahead: take the deposit hold at the pickup', () => {
  const s = nextStep(x({ status: 'confirmed', depositCents: 50000, depositStatus: null }));
  assert.equal(s.step, 'deposit');
  assert.match(s.text, /take the \$500\.00 deposit hold/);
  assert.equal(s.action, undefined);
  // held already, or an insurer pays: straight to the check-out at the pickup
  assert.equal(nextStep(x({ status: 'confirmed', depositCents: 50000, depositStatus: 'held' })).step, 'checkout');
  assert.equal(nextStep(x({ status: 'confirmed', depositCents: 50000, insurerBilled: true })).step, 'checkout');
});

test('confirmed, pickup today: check out the car (and the deposit when not held)', () => {
  const s = nextStep(x({ status: 'confirmed', pickupAt: '2026-10-30T20:00:00Z', depositCents: 50000 }));
  assert.equal(s.step, 'checkout');
  assert.match(s.text, /^Pickup is .*No deposit yet: take the \$500\.00 deposit hold now, then check out the car\./);
  assert.equal(s.action?.testId, 'next-step-checkout');
  assert.match(nextStep(x({ status: 'confirmed', pickupAt: '2026-10-29T20:00:00Z' })).text, /^Pickup was/);
});

test('on_rent: return due, check in; late says so', () => {
  const s = nextStep(x({ status: 'on_rent' }));
  assert.equal(s.step, 'checkin');
  assert.match(s.text, /Return due Sun, Nov 8, 9:00/);
  assert.equal(s.action?.label, 'Check in the car');
  assert.match(nextStep(x({ status: 'on_rent', returnAt: '2026-10-29T14:00:00Z' })).text, /^The return was due/);
});

test('returned: settle the deposit (Finance); closed and the ends: nothing to do', () => {
  const s = nextStep(x({ status: 'returned', depositCents: 50000, depositStatus: 'held' }));
  assert.equal(s.step, 'settle');
  assert.equal(s.who, 'Finance');
  assert.equal(s.action?.href, `${base}?tab=money#c-deposit`);
  assert.equal(nextStep(x({ status: 'returned', can: { settle: false } })).action, undefined);
  assert.equal(nextStep(x({ status: 'closed' })).step, 'closed');
  for (const st of ['cancelled', 'declined', 'expired']) { const e = nextStep(x({ status: st })); assert.equal(e.step, 'done'); assert.equal(e.action, undefined); }
  assert.match(nextStep(x({ status: 'expired' })).text, /never became a booking/);
  assert.equal(nextStep(x({ status: 'tentative' })).step, 'other');
});

test('the words: no dashes or codes in any sentence', () => {
  for (const st of ['requested', 'offered', 'pending_payment', 'confirmed', 'on_rent', 'returned', 'closed', 'cancelled', 'declined', 'expired']) {
    const s = nextStep(x({ status: st, offerExpiresAt: '2026-10-31T14:00:00Z', dueCents: 1000, depositCents: 100 }));
    assert.doesNotMatch(s.text, /[–—_]/, st);
  }
});

test('Release 24b: the licence comes first, and the essentials show what is done', () => {
  const s = nextStep(x({ status: 'confirmed', licenceOk: false, awaitingSignature: true, depositCents: 50000 }));
  assert.equal(s.step, 'licence');
  assert.equal(s.action?.testId, 'next-step-licence');
  assert.deepEqual(s.essentials?.map((e) => `${e.key}:${e.done}`), ['licence:false', 'agreement:false', 'deposit:false', 'checkout_photos:false']);
  const ok = nextStep(x({ status: 'confirmed', licenceOk: true, depositCents: 50000, depositStatus: 'held' }));
  assert.deepEqual(ok.essentials?.filter((e) => !e.done).map((e) => e.key), ['checkout_photos']);
  const out = nextStep(x({ status: 'on_rent', licenceOk: true, depositCents: 50000, depositStatus: 'held' }));
  assert.deepEqual(out.essentials?.map((e) => `${e.key}:${e.done}`), ['licence:true', 'agreement:true', 'deposit:true', 'checkout_photos:true', 'checkin:false']);
  assert.equal(nextStep(x({ status: 'closed' })).essentials, undefined);
});
