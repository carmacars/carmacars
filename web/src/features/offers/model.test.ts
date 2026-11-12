import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cents, daysBetween, describeRevision, feeOverrides, lineKey, missing, offerChannels, offerPayload, paidSoFar, paymentOf, periodShares, typedRental, needsReference, type OfferForm } from './model.ts';

const base = (o: Partial<OfferForm> = {}): OfferForm => ({
  renter_id: null, full_name: 'Nora Offer', email: 'nora@example.test', mobile: '416 555 0177', date_of_birth: '1991-02-03',
  vehicle_id: 'car-1', pickup_at: '2026-11-02T10:00', return_at: '2026-11-05T10:00',
  pickup_kind: 'our_location', pickup_address: '', pickup_km: '', return_kind: 'delivery', return_address: '12 King St W', return_km: '14',
  price_mode: 'sheet', price_total: '', price_day: '', price_tax: 'plus', price_reason: '',
  deposit: '', discount: '', discount_reason: '', promo_code: '', km: '', coverage_option: '1', plan_price: '', fees: {}, fee_reason: '',
  rental_pay: 'card', deposit_pay: 'card', choice: '', message: '', note: '', hours: '24', by_email: false, by_text: true, notify: true, ...o
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
  const f = base({ pickup_kind: 'delivery', pickup_address: '1 Main St', deposit: '500', discount: '20', fees: { delivery: '0', young_driver_21_25: '150' }, coverage_option: '3', plan_price: '15' });
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

test('amounts typed after tax (2026-10-27): the rental charge goes tax included, each HST line before tax, lines without HST as typed', () => {
  const hst = (k: string) => k !== 'collection_cost';
  const f = base({ price_mode: 'total', price_total: '270', price_reason: 'Paid $320 cash', coverage_option: '3', plan_price: '50', fees: { collection_cost: '25' } });
  const p = offerPayload(f, 'admin', 3, [], true, { after: true, bps: 1300, hstFor: hst });
  assert.equal(p.rental_charge_cents, 27000);
  assert.equal(p.price_tax, 'included');
  assert.deepEqual(p.line_overrides, { coverage_sold: 4425, collection_cost: 2500 });
  // before tax: as typed, plus tax
  const b = offerPayload(f, 'admin', 3, [], true, { after: false, bps: 1300, hstFor: hst });
  assert.equal(b.price_tax, 'plus');
  assert.deepEqual(b.line_overrides, { coverage_sold: 5000, collection_cost: 2500 });
  // a fee typed $1.00 after tax lands a cent short (0.88 + 0.11): the rental charge takes the cent
  const odd = offerPayload(base({ pickup_kind: 'delivery', pickup_address: '1 Main St', price_mode: 'total', price_total: '270', price_reason: 'x', fees: { delivery: '1' } }), 'admin', 3, [], true, { after: true, bps: 1300, hstFor: hst });
  assert.equal(odd.rental_charge_cents, 27001);
  assert.deepEqual(odd.line_overrides, { delivery: 88 });
  // the total the renter pays: the rental charge worked out, tax included, with a reason when none was typed
  const t = offerPayload(base(), 'cs', 3, [], false, { after: false, bps: 1300, hstFor: hst, rentalWithTax: 27000 });
  assert.equal(t.rental_charge_cents, 27000);
  assert.equal(t.price_tax, 'included');
  assert.equal(t.price_reason, 'Total agreed with the renter');
  // no price yet (no rate known): typed as they are, the rental still tax included
  const n = offerPayload(f, 'admin', 3, [], true, { after: true, bps: null, hstFor: hst });
  assert.equal(n.price_tax, 'included');
  assert.deepEqual(n.line_overrides, { coverage_sold: 5000, collection_cost: 2500 });
});

// 2026-11-01: the link goes by text by default; without a mobile number it goes by email
test('offerChannels: text by default, email when there is no mobile number', () => {
  assert.deepEqual(offerChannels(base({})), { email: false, text: true });
  assert.deepEqual(offerChannels(base({ mobile: '' })), { email: true, text: false });
  assert.deepEqual(offerChannels(base({ by_email: true, by_text: true })), { email: true, text: true });
  assert.deepEqual(offerChannels(base({ by_email: true, by_text: false, mobile: '' })), { email: true, text: false });
  assert.deepEqual(offerPayload(base({ mobile: '' }), 'admin', 3).channels, { email: true, text: false });
});

// ---------------------------------------------------------------- Release 24: choices drive charges
import { droppedByPrice, lineLive, liveFees, offerChoices, youngBand } from './model.ts';

test('a fee line lives only while the choice that makes it is chosen', () => {
  const c = { pickup_kind: 'our_location', return_kind: 'airport', coverage_option: '1', addons: ['gps'], young_bands: [] as Array<'18_20' | '21_25'>, additional_driver: false };
  assert.equal(lineLive('delivery', c), false);
  assert.equal(lineLive('delivery', { ...c, pickup_kind: 'delivery' }), true);
  assert.equal(lineLive('pickup', c), true);
  assert.equal(lineLive('coverage_sold', c), false);
  assert.equal(lineLive('coverage_sold', { ...c, coverage_option: 3 }), true);
  assert.equal(lineLive('addon:gps', c), true);
  assert.equal(lineLive('addon:baby_seat', c), false);
  assert.equal(lineLive('young_driver_21_25', c), false);
  assert.equal(lineLive('young_driver_21_25', { ...c, young_bands: ['21_25'] }), true);
  assert.equal(lineLive('additional_driver', c), false);
  assert.equal(lineLive('custom_fee', c), true);
  // a choice the screen does not know is never judged here
  assert.equal(lineLive('delivery', {}), true);
  assert.equal(lineLive('young_driver_18_20', {}), true);
});

test('fees set by hand are dropped with their choice; the same object when nothing is dropped', () => {
  const fees = { delivery: '75', pickup: '60', coverage_sold: '40', young_driver_21_25: '30' };
  assert.deepEqual(liveFees(fees, { pickup_kind: 'our_location', return_kind: 'delivery', coverage_option: '1' }), { pickup: '60', young_driver_21_25: '30' });
  assert.equal(liveFees(fees, { pickup_kind: 'delivery', return_kind: 'delivery', coverage_option: '3' }), fees);
});

test('the offer payload never carries the fee of a choice removed (delivery removed: no delivery fee sent)', () => {
  const withDelivery = offerPayload(base({ pickup_kind: 'delivery', pickup_address: '1 Main St', pickup_km: '10', fees: { delivery: '90', pickup: '50' } }), 'admin', 3);
  assert.deepEqual(withDelivery.line_overrides, { delivery: 9000, pickup: 5000 });
  const removed = offerPayload(base({ pickup_kind: 'our_location', fees: { delivery: '90', pickup: '50' } }), 'admin', 3);
  assert.deepEqual(removed.line_overrides, { pickup: 5000 });
  const none = offerPayload(base({ pickup_kind: 'our_location', return_kind: 'our_location', fees: { delivery: '90', pickup: '50' } }), 'admin', 3);
  assert.equal(none.line_overrides, undefined);
  assert.equal(none.fee_reason, undefined);
  // the Protection Plan price typed goes with option 3 only; an add-on's price with the add-on
  assert.equal((offerPayload(base({ coverage_option: '2', plan_price: '40' }), 'admin', 3).line_overrides as Record<string, number> | undefined)?.coverage_sold, undefined);
  assert.deepEqual(offerPayload(base({ return_kind: 'our_location', fees: { 'addon:gps': '12' } }), 'admin', 3, [{ code: 'gps', quantity: 1 }]).line_overrides, { 'addon:gps': 1200 });
  assert.equal(offerPayload(base({ return_kind: 'our_location', fees: { 'addon:gps': '12' } }), 'admin', 3, []).line_overrides, undefined);
  assert.deepEqual(offerChoices(base()), { pickup_kind: 'our_location', return_kind: 'delivery', coverage_option: '1' });
});

test('the fees the database priced away are found from the fresh lines', () => {
  const lines = [{ charge_type: 'rental_charge', stage: 'booking' }, { charge_type: 'delivery', stage: 'booking' }, { charge_type: 'addon', booking_addon_id: 'x', addon_code: 'gps', stage: 'booking' }];
  assert.deepEqual(droppedByPrice({ delivery: 1, young_driver_21_25: 2, 'addon:gps': 3, 'addon:seat': 4 }, lines), ['young_driver_21_25', 'addon:seat']);
});

test('age bands on the pickup day, as the database bands them', () => {
  assert.equal(youngBand('2005-11-10', '2026-11-09T10:00'), '18_20');
  assert.equal(youngBand('2005-11-10', '2026-11-10T10:00'), '21_25');
  assert.equal(youngBand('2006-11-10', '2026-11-09T10:00'), '18_20');
  assert.equal(youngBand('1990-01-01', '2026-11-09T10:00'), null);
  assert.equal(youngBand('', '2026-11-09T10:00'), null);
});

import { firstName, missingFields } from './model.ts';
test('what is missing, next to its field, in plain words', () => {
  const none = base({ full_name: '', email: 'x', mobile: '12', date_of_birth: '', vehicle_id: '', choice: '' });
  assert.deepEqual(missingFields(none, 'sales').map((m) => m.short), ['renter', 'car', 'who found this client']);
  assert.deepEqual(missingFields(none, 'admin', { adding: true }).map((m) => m.field), ['full_name', 'email', 'mobile', 'date_of_birth', 'vehicle_id']);
  assert.deepEqual(missingFields(base({ return_at: '2026-11-02T09:00' }), 'admin', { adding: true }).map((m) => m.say), ['The return must be after the pickup.']);
  assert.deepEqual(missingFields(base({ price_mode: 'total' }), 'admin', { adding: true }).map((m) => m.short), ['price', 'reason for the price']);
  assert.deepEqual(missingFields(base({ renter_id: 'r1' }), 'admin'), []);
  assert.equal(firstName('  Nora  Offer '), 'Nora');
  assert.equal(firstName(''), '');
});

// 2026-11-11: "Amounts I type: Before tax | After tax" on the price step, end to end: the payload the database prices
test('the toggle: a total typed after tax goes tax included, before tax goes plus tax', () => {
  const tax = (after: boolean) => ({ after, bps: 1300, hstFor: () => true });
  for (const [typed, c] of [['410.19', 41019], ['1490', 149000]] as const) {
    const a = offerPayload(base({ price_mode: 'total', price_total: typed, price_reason: 'Agreed' }), 'admin', 3, [], true, tax(true));
    assert.deepEqual([a.rental_charge_cents, a.price_tax], [c, 'included']);
    const b = offerPayload(base({ price_mode: 'total', price_total: typed, price_reason: 'Agreed' }), 'admin', 3, [], true, tax(false));
    assert.deepEqual([b.rental_charge_cents, b.price_tax], [c, 'plus']);
  }
  // a fee typed after tax goes before tax ($56.50 with HST is $50.00), its rounding cent on the rental charge
  const f = offerPayload(base({ price_mode: 'total', price_total: '410.19', price_reason: 'Agreed', fees: { delivery_fee: '56.50' } as OfferForm['fees'] }), 'admin', 3, [], true, tax(true));
  assert.equal((f.line_overrides as Record<string, number>).delivery_fee, 5000);
  assert.equal(f.rental_charge_cents, 41019);
});
