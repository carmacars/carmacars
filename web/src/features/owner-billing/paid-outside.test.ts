import { test } from 'node:test';
import assert from 'node:assert/strict';
import { outsidePayment } from './paid-outside.ts';

const base = { method: 'e_transfer', received_on: '2026-11-05', reference: 'CA123456', note: '', amount: '' };

test('an e-Transfer with its reference is recorded as it is, for the full balance', () => {
  const r = outsidePayment(base, '2026-11-07');
  assert.deepEqual(r, { ok: true, payment: { method: 'e_transfer', reference: 'CA123456', note: null, received_on: '2026-11-05', amount_cents: null } });
});

test('a card paid outside the platform is recorded as "other" and says so in the note', () => {
  const r = outsidePayment({ ...base, method: 'card_outside', reference: '', note: 'Visa on the phone' }, '2026-11-07');
  assert.ok(r.ok);
  if (r.ok) assert.deepEqual([r.payment.method, r.payment.note, r.payment.reference], ['other', 'Paid by card outside the platform. Visa on the phone', null]);
});

test('cash needs no reference; an e-Transfer, cheque or bank transfer does', () => {
  assert.ok(outsidePayment({ ...base, method: 'cash', reference: '' }, '2026-11-07').ok);
  for (const method of ['e_transfer', 'cheque', 'bank_transfer']) assert.equal(outsidePayment({ ...base, method, reference: '' }, '2026-11-07').ok, false);
});

test('a future date, a bad date and a bad amount are refused; a typed amount becomes cents', () => {
  assert.equal(outsidePayment({ ...base, received_on: '2026-11-08' }, '2026-11-07').ok, false);
  assert.equal(outsidePayment({ ...base, received_on: '' }, '2026-11-07').ok, false);
  assert.equal(outsidePayment({ ...base, amount: 'abc' }, '2026-11-07').ok, false);
  const r = outsidePayment({ ...base, amount: '$1,130.50' }, '2026-11-07');
  assert.ok(r.ok);
  if (r.ok) assert.equal(r.payment.amount_cents, 113050);
});
