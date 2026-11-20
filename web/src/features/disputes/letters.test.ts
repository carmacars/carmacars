import { test } from 'node:test';
import assert from 'node:assert/strict';
import { coverLetter, reasonOf, type LetterInput } from './letters.ts';

const base: LetterInput = { reason: null, variant: 'card', bookingNumber: 'CC-10478', agreementNumber: 'RA-10478', renter: 'Zion Renter', car: '2022 Kia Forte',
  from: '2026-11-01T14:00:00Z', to: '2026-11-08T14:00:00Z', handedOver: '2026-11-01T14:10:00Z', returned: '2026-11-08T15:00:00Z', amountCents: 33900,
  charges: [{ label: 'Smoking fee', amount_cents: 30000, clause: 'Part 3 Smoking fee; 10.2 Prohibited uses', evidence: ['the guided evidence photos', 'a written description'], notice_sent_at: '2026-11-09T12:00:00Z', notice_status: 'sent' }],
  signedWithCode: true, signedAt: '2026-10-30T18:00:00Z', ip: '203.0.113.9', idChecked: true, faceMatch: 0.94, previousTrips: 2, sameCardTrips: 1, avs: 'pass', cvc: 'pass', threeDs: null, refundsCents: 0, paymentsCount: 2 };

const letter = (reason: string) => coverLetter({ ...base, reason });

test('fraud: the cardholder made the rental, with the identity proof', () => {
  const l = letter('fraudulent');
  assert.match(l.title, /cardholder made this rental/);
  assert.ok(l.paragraphs.some((p) => /one-time code/.test(p) && /selfie matched/.test(p) && /203\.0\.113\.9/.test(p)));
  assert.match(l.stripe['evidence[uncategorized_text]']!, /Smoking fee: \$300\.00 plus tax, under Part 3 Smoking fee/);
});

test('not recognised: names the rental and the receipts', () => {
  const l = letter('unrecognized');
  assert.match(l.paragraphs[0]!, /does not recognize the charge.*CC-10478/);
  assert.equal(reasonOf('not_recognised'), 'unrecognized');
});

test('not received: the car was handed over, with the service date', () => {
  const l = letter('product_not_received');
  assert.match(l.paragraphs[0]!, /handed over/);
  assert.equal(l.stripe['evidence[service_date]'], '2026-11-01');
});

test('credit not processed: no credit owed, the refund refusal staged', () => {
  const l = coverLetter({ ...base, reason: 'credit_not_processed', refundsCents: 5000 });
  assert.match(l.paragraphs[0]!, /\$50\.00 was refunded already/);
  assert.ok(l.stripe['evidence[refund_refusal_explanation]']);
});

test('duplicate: each charge is separate', () => {
  const l = letter('duplicate');
  assert.match(l.paragraphs[0]!, /Each charge is separate/);
  assert.ok(l.stripe['evidence[duplicate_charge_explanation]']);
});

test('every charge names its clause and its notice before billing', () => {
  for (const r of ['fraudulent', 'unrecognized', 'product_not_received', 'credit_not_processed', 'duplicate', 'subscription_canceled', 'general']) {
    const text = letter(r).paragraphs.join('\n');
    assert.match(text, /under Part 3 Smoking fee/, r);
    assert.match(text, /told before it was billed on 2026-11-09/, r);
  }
});

test('the non-card packs: e-Transfer or cash, insurer billing, small claims', () => {
  assert.match(coverLetter({ ...base, variant: 'etransfer_cash' }).paragraphs[0]!, /e-Transfer or cash/);
  assert.match(coverLetter({ ...base, variant: 'insurer' }).paragraphs[0]!, /adjuster/);
  const sc = coverLetter({ ...base, variant: 'small_claims' });
  assert.match(sc.title, /Small claims bundle: CarmaCars v\. Zion Renter/);
  assert.match(sc.paragraphs[0]!, /claim of \$339\.00/);
  assert.deepEqual(coverLetter({ ...base, variant: 'insurer' }).stripe, {});
});
