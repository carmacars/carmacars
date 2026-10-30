import { test } from 'node:test';
import assert from 'node:assert/strict';
import { handoverPanelView } from './panel.ts';
import type { Signer, SigningState } from './types.ts';

// The booking page's check-out, check-in and signing card (0185): a booking waiting for payment whose renter has not
// signed offers "Sign now on this device"; the card is never shown empty.
const licence = { expiry: null, expiry_ok: true, missing: [], complete: true };
const signer = (role: Signer['role'], name: string, signed = false): Signer => ({ id: `${role}-${name}`, role, name, signed_at: signed ? '2026-10-28T12:00:00Z' : null, driver_id: null, in_person: null, licence });
const state = (o: Partial<SigningState> & { agreement?: SigningState['agreement'] | null; signers?: Signer[] }): SigningState => ({
  booking_id: 'b', booking_number: 'CC-1', status: 'pending_payment', renter_user_id: 'u', renter_mobile: null, renter_email: null, added: false, link_due: false,
  companion: null, signers: [], agreement: null, ...o
});
const agreement = (status: string) => ({ id: 'a', status, document_id: 'd', document_sha256: 'e'.repeat(64), agreement_number: 'RA-1' });

test('waiting for payment, the renter has not signed: Sign now on this device, the signing link, no check-out', () => {
  const v = handoverPanelView({ status: 'pending_payment', canHandover: true, late: false, signing: state({ agreement: agreement('open'), signers: [signer('renter', 'Paula Before')] }) });
  assert.equal(v.show, true);
  assert.equal(v.signNow, true);
  assert.equal(v.sendLink, true);
  assert.deepEqual(v.waiting, ['Paula Before']);
  assert.equal(v.checkout, false);
  assert.match(v.note ?? '', /not signed/);
});

test('waiting for payment, no agreement made yet: Sign now prepares it (staff who may sign but not hand over too)', () => {
  for (const canHandover of [true, false]) {
    const v = handoverPanelView({ status: 'pending_payment', canHandover, late: false, signing: state({ agreement: null }) });
    assert.equal(v.show, true);
    assert.equal(v.signNow, true);
    assert.match(v.note ?? '', /prepares it/);
  }
});

test('confirmed on a payment before signing: Sign now, the check-out, and the car waits for the signature', () => {
  const v = handoverPanelView({ status: 'confirmed', canHandover: true, late: false, signing: state({ status: 'confirmed', paid_unsigned: true, agreement: agreement('open'), signers: [signer('renter', 'Paula Before')] }) });
  assert.equal(v.signNow, true);
  assert.equal(v.checkout, true);
  assert.match(v.note ?? '', /not released until they do/);
});

test('waiting for payment, the renter signed online: no empty card, it says what comes next', () => {
  const v = handoverPanelView({ status: 'pending_payment', canHandover: true, late: false, signing: state({ agreement: agreement('signed'), signers: [signer('renter', 'Paula Before', true)] }) });
  assert.equal(v.show, true);
  assert.equal(v.signNow, false);
  assert.match(v.note ?? '', /countersigns once the amount due at booking is paid/);
});

test('an additional driver still signs: listed, Sign now; the renter signed so no signing link', () => {
  const v = handoverPanelView({ status: 'confirmed', canHandover: true, late: false, signing: state({ status: 'confirmed', agreement: agreement('signed'), signers: [signer('renter', 'Paula Before', true), signer('additional_driver', 'Dan Driver')] }) });
  assert.equal(v.signNow, true);
  assert.equal(v.sendLink, false);
  assert.deepEqual(v.waiting, ['Dan Driver']);
});

test('nothing to show: no card (finance on a booking waiting for payment, or signing state not readable)', () => {
  assert.equal(handoverPanelView({ status: 'pending_payment', canHandover: false, late: false, signing: null }).show, false);
  assert.equal(handoverPanelView({ status: 'pending_payment', canHandover: true, late: false, signing: null }).show, false);
});

test('on rent and after: check-in, the photo report; completed agreements add nothing', () => {
  const v = handoverPanelView({ status: 'on_rent', canHandover: true, late: false, signing: state({ status: 'on_rent', agreement: agreement('completed'), signers: [signer('renter', 'Paula Before', true)] }) });
  assert.equal(v.checkin, true);
  assert.equal(v.report, true);
  assert.equal(v.signNow, false);
  assert.equal(v.note, null);
  assert.equal(handoverPanelView({ status: 'returned', canHandover: false, late: false, signing: null }).report, true);
});
