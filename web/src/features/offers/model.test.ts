import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cents, daysBetween, describeRevision, feeOverrides, lineKey, missing, offerPayload, paidSoFar, paymentOf, periodShares, typedRental, needsReference, type OfferForm } from './model.ts';

const base = (o: Partial<OfferForm> = {}): OfferForm => ({
  renter_id: null, full_name: 'Nora Offer', email: 'nora@example.test', mobile: '416 555 0177', date_of_birth: '1991-02-03',
  vehicle_id: 'car-1', pickup_at: '2026-11-02T10:00', return_at: '2026-11-05T10:00',
  pickup_kind: 'our_location', pickup_address: '', pickup_km: '', return_kind: 'delivery', return_address: '12 King St W', return_km: '14',
  price_mode: 'sheet', price_total: '', price_day: '', price_tax: 'plus', price_reason: '',
  deposit: '', discount: '', discount_reason: '', promo_code: '', km: '', coverage_option: '1', plan_price: '', fees: {}, fee_reason: '',
  rental_pay: 'card', deposit_pay: 'card', choice: '', message: '', note: '', hours: '24', by_email: true, by_text: false, notify: true, ...o
});

test('money typed in dollars becomes cents; empty or bad is nothing', () => {
  assert.equal(cents('$1,234.50'), 123450);
  assert.equal(cents('99'), 9900);
  assert.equal(cents(''), null);
  assert.equal(cents('abc'), null);
  assert.equal(cents('-5'), null);
});

test('days: 24-hour periods, at least one, none when the return is not after the pickup', () => {
  assert.equal(daysBetween('2026-11-02T10:00', '2026-11-05T10:00'), 3);
  assert.equal(daysBetween('2026-11-02T10:00', '2026-11-05T11:00'), 4);
  assert.equal(daysBetween('2026-11-02T10:00', '2026-11-02T12:00'), 1);
  assert.equal(daysBetween('2026-11-02T10:00', '2026-11-02T10:00'), 0);
});

test('the price typed: a total, or a rate per day times the days, or the rate sheet', () => {
  assert.equal(typedRental(base({ price_mode: 'total', price_total: '250' }), 3), 25000);
  assert.equal(typedRental(base({ price_mode: 'day', price_day: '85' }), 3), 25500);
  assert.equal(typedRental(base(), 3), null);
});

test('what is missing, in words; an assistant must say who found the client', () => {
  assert.deepEqual(missing(base(), 'admin'), []);
  assert.deepEqual(missing(base(), 'cs'), ['who found this client']);
  assert.deepEqual(missing(base({ email: 'no', mobile: '123', price_mode: 'total' }), 'admin'), ['an email for the offer link', 'a mobile number', 'the price', 'the reason for the price']);
  assert.deepEqual(missing(base({ renter_id: 'r1', full_name: '', email: '', mobile: '', date_of_birth: '' }), 'admin'), []);
});

test('the payload: a new customer, the places, the price typed, the payment plan and how the renter hears of it', () => {
  const p = offerPayload(base({ price_mode: 'total', price_total: '250', price_reason: 'Phone deal', rental_pay: 'e_transfer', deposit_pay: 'cash', by_email: false, by_text: true, choice: 'sourced' }), 'cs', 3);
  assert.deepEqual(p.renter, { full_name: 'Nora Offer', email: 'nora@example.test', mobile: '416 555 0177', date_of_birth: '1991-02-03' });
  assert.deepEqual(p.return_location, { kind: 'delivery', address: '12 King St W', distance_km: 14, airport_code: null });
  assert.equal(p.rental_charge_cents, 25000);
  assert.equal(p.price_reason, 'Phone deal');
  assert.equal(p.rental_pay_method, 'e_transfer');
  assert.equal(p.deposit_pay_method, 'cash');
  assert.deepEqual(p.channels, { email: false, text: true });
  assert.equal(p.notify, true);
  assert.equal(p.sales_choice, 'sourced');
});

test('an assistant never sends the deposit or a discount; fees only when allowed (0132); an Admin does', () => {
  const f = base({ deposit: '500', discount: '20', fees: { delivery: '0', young_driver_21_25: '150' }, coverage_option: '3', plan_price: '15' });
  const va = offerPayload(f, 'sales', 3);
  assert.equal(va.deposit_cents, undefined);
  assert.equal(va.line_overrides, undefined, 'fees not allowed: none sent');
  assert.equal(va.changes, undefined);
  const cs = offerPayload(f, 'cs', 3, [], true);
  assert.deepEqual(cs.line_overrides, { delivery: 0, young_driver_21_25: 15000, coverage_sold: 1500 });
  assert.equal(cs.deposit_cents, undefined);
  const admin = offerPayload(f, 'admin', 3);
  assert.equal(admin.deposit_cents, 50000);
  assert.deepEqual(admin.line_overrides, { delivery: 0, young_driver_21_25: 15000, coverage_sold: 1500 });
  assert.equal(admin.fee_reason, 'Agreed with the renter');
  assert.deepEqual(admin.changes, { staff_discount_cents: 2000, staff_discount_reason: 'Discount given on the phone' });
});

test('fee lines, payments in parts and period shares (0132)', () => {
  assert.equal(lineKey({ charge_type: 'young_driver_21_25' }), 'young_driver_21_25');
  assert.equal(lineKey({ charge_type: 'winter_tire', detail: { code: 'winter-tires', addon_id: 'x' } }), 'addon:winter-tires');
  assert.deepEqual(feeOverrides({ rental_charge: '10', coverage_sold: '40.5', delivery: '' }), { coverage_sold: 4050 });
  assert.deepEqual(paidSoFar(300000, [{ method: 'e_transfer', amount: '2,000', reference: 'X1' }], 548050), { paid: 500000, left: 48050 });
  assert.deepEqual(paidSoFar(600000, [], 548050), { paid: 600000, left: 0 });
  assert.deepEqual(periodShares(100, [30, 12]), [71, 29]);
  assert.deepEqual(periodShares(0, []), []);
});

test('not notified when neither email nor text is ticked', () => {
  assert.equal(offerPayload(base({ by_email: false, by_text: false }), 'admin', 3).notify, false);
  assert.equal(offerPayload(base({ notify: false }), 'admin', 3).notify, false);
});

test('a customer on file: only the id', () => {
  const p = offerPayload(base({ renter_id: 'r1' }), 'admin', 3);
  assert.equal(p.renter_id, 'r1');
  assert.equal(p.renter, undefined);
});

test('the revision in words', () => {
  const lines = describeRevision({ vehicle: 'Kia K5', total_cents: 30000, deposit_cents: 30000 }, { vehicle: 'Kia K5', total_cents: 33900, deposit_cents: 40000 },
    (c) => `$${(c / 100).toFixed(2)}`, (x) => x);
  assert.deepEqual(lines, ['Total: $300.00 to $339.00', 'Deposit: $300.00 to $400.00']);
});

test('the quick rental\'s "paid by" maps to the way and the method', () => {
  assert.deepEqual(paymentOf('e_transfer'), { mode: 'other_way', method: 'e_transfer' });
  assert.deepEqual(paymentOf('platform_payout'), { mode: 'other_way', method: 'platform_payout' });
  assert.deepEqual(paymentOf('insurer'), { mode: 'unpaid', method: 'insurer' });
  assert.deepEqual(paymentOf('card_on_file'), { mode: 'card' });
  assert.deepEqual(paymentOf('link'), { mode: 'link' });
  assert.equal(needsReference('e_transfer'), true);
  assert.equal(needsReference('cash'), false);
});
