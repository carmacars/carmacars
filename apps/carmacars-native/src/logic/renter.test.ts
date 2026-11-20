import { test } from 'node:test';
import assert from 'node:assert/strict';
import { activeCount, datesProblem, familyOf, makeOptions, noFilters, searchCars } from './search.ts';
import { ageOn, emptyForm, requestData, requestKey, stepErrors, type Form } from './booking.ts';
import { nextStep, sortTrips } from './trip.ts';
import { targetFor } from './links.ts';
import { consentsLeft, initialsLeft, initialsOf, progress, stageOf } from './esign.ts';
import type { Available, CarCard, EsignView } from '../shared.ts';

const car = (slug: string, make: string, model: string, trim: string | null, o: Partial<CarCard> = {}): CarCard => ({ vehicle_id: `v-${slug}`, slug, year: 2023, make, model, trim, classes: ['sedan'], seats: 5,
  transmission: 'Automatic', fuel: 'gas', daily_rate_cents: 9000, cover: null, ...o });
const CARS = [car('c300', 'Mercedes-Benz', 'C300', '4MATIC'), car('c-class', 'Mercedes-Benz', 'C-Class', 'C300', { daily_rate_cents: 11000 }), car('glc', 'Mercedes-Benz', 'GLC', 'GLC300', { classes: ['suv'], daily_rate_cents: 14000 }),
  car('civic', 'Honda', 'Civic', 'LX', { daily_rate_cents: 6000, transmission: 'Manual' }), car('sienna', 'Toyota', 'Sienna', null, { classes: ['van'], seats: 8, daily_rate_cents: 12000 })];
const quote = (slug: string, daily: number): Available => ({ vehicle_id: `v-${slug}`, slug, daily_rate_cents: daily, billable_days: 3, rental_charge_cents: daily * 3, subtotal_cents: daily * 3, hst_cents: 0, total_cents: daily * 3, deposit_cents: 50000 });

// ---------------------------------------------------------------- search
test('search: "C300" and "C-Class" are one model family, as on the site', () => {
  assert.equal(familyOf(CARS[0]!).model, 'C-Class');
  assert.equal(familyOf(CARS[1]!).model, 'C-Class');
  const o = makeOptions(CARS, 'Mercedes-Benz');
  assert.deepEqual(o.makes, ['Honda', 'Mercedes-Benz', 'Toyota']);
  assert.deepEqual(o.families.map((f) => f.model), ['C-Class', 'GLC']);
  assert.deepEqual(makeOptions(CARS, null).families, []);
  assert.deepEqual(searchCars(CARS, { ...noFilters(), make: 'Mercedes-Benz', family: 'C-Class' }, null).map((h) => h.car.slug), ['c300', 'c-class']);
});

test('search: type, seats, transmission and the daily rate narrow the list; the count is the badge', () => {
  assert.deepEqual(searchCars(CARS, { ...noFilters(), classes: ['suv', 'van'] }, null).map((h) => h.car.slug), ['glc', 'sienna']);
  assert.deepEqual(searchCars(CARS, { ...noFilters(), seats: 7 }, null).map((h) => h.car.slug), ['sienna']);
  assert.deepEqual(searchCars(CARS, { ...noFilters(), transmission: 'manual' }, null).map((h) => h.car.slug), ['civic']);
  assert.deepEqual(searchCars(CARS, { ...noFilters(), maxDailyCents: 9000 }, null).map((h) => h.car.slug), ['c300', 'civic']);
  assert.equal(activeCount({ ...noFilters(), classes: ['suv', 'van'], seats: 7, maxDailyCents: 9000 }), 4);
  assert.equal(activeCount(noFilters()), 0);
});

test('search: with dates, only the free cars show, at the price for those dates', () => {
  const free = [quote('civic', 7500), quote('glc', 13000)];
  const hits = searchCars(CARS, noFilters(), free, 'price_low');
  assert.deepEqual(hits.map((h) => [h.car.slug, h.quote?.total_cents]), [['civic', 22500], ['glc', 39000]]);
  // the rate filter follows the dates' rate, not the list rate (the Civic is $75 a day that weekend, not $60)
  assert.deepEqual(searchCars(CARS, { ...noFilters(), maxDailyCents: 7000 }, free).map((h) => h.car.slug), []);
  assert.deepEqual(searchCars(CARS, noFilters(), [], 'price_high'), []);
  assert.deepEqual(searchCars(CARS, noFilters(), null, 'price_high').map((h) => h.car.slug)[0], 'glc');
});

test('search: dates in the past, backwards or too long are said before the server is asked', () => {
  assert.equal(datesProblem('2026-11-19', '2026-11-22', '2026-11-20', 30), 'The pickup date has passed.');
  assert.equal(datesProblem('2026-11-22', '2026-11-22', '2026-11-20', 30), 'The return date must be after the pickup date.');
  assert.equal(datesProblem('2026-11-22', '2027-01-22', '2026-11-20', 30), 'The longest rental is 30 days.');
  assert.equal(datesProblem('2026-11-20', '2026-11-22', '2026-11-20', 30), null);
  assert.equal(datesProblem(null, '2026-11-22', '2026-11-20', 30), null);
});

// ---------------------------------------------------------------- request to book
const RULES = { min_age: 21, max_days: 30, notice_minutes: 120, licence_classes: ['G', 'G2'] };
const CTX = { todayIso: '2026-11-20', nowMinutes: 9 * 60 };
const filled = (o: Partial<Form> = {}): Form => ({ ...emptyForm('civic', '2026-11-21', '2026-11-24'), first: 'Rita', last: 'Renter', email: 'rita@example.test', phone: '647-555-0199', dobY: '1990', dobM: '5', dobD: '5',
  licClass: 'G', coverage: '3', agree: true, ...o });

test('request: the dates step says what to change, with the site\'s rules', () => {
  assert.deepEqual(stepErrors(1, filled(), RULES, CTX), {});
  assert.equal(stepErrors(1, filled({ from: '' }), RULES, CTX).from, 'Choose the pickup date.');
  assert.equal(stepErrors(1, filled({ from: '2026-11-19' }), RULES, CTX).from, 'The pickup date has passed.');
  assert.equal(stepErrors(1, filled({ to: '2026-11-21', tt: '09:00' }), RULES, CTX).to, 'The return must be after the pickup.');
  assert.equal(stepErrors(1, filled({ to: '2027-01-30' }), RULES, CTX).to, 'The longest rental is 30 days. For longer, call us.');
  // today at 10:00 with two hours of notice asked at 9:00: too soon; 11:00 is fine
  assert.equal(stepErrors(1, filled({ from: '2026-11-20', tf: '10:00' }), RULES, CTX).tf, 'Pick a time at least 2 hours from now.');
  assert.equal(stepErrors(1, filled({ from: '2026-11-20', tf: '11:00' }), RULES, CTX).tf, undefined);
  assert.equal(stepErrors(1, filled({ pickupAt: 'airport' }), RULES, CTX).pickupAirport, 'Choose the airport.');
});

test('request: the driver must be old enough on the pickup date, not today', () => {
  assert.equal(ageOn('2005', '11', '22', '2026-11-21'), 20);
  assert.equal(ageOn('2005', '11', '21', '2026-11-21'), 21);
  assert.equal(ageOn('2005', '2', '30', '2026-11-21'), null);
  assert.equal(stepErrors(2, filled({ dobY: '2005', dobM: '11', dobD: '22' }), RULES, CTX).dob, 'Drivers must be at least 21 on the pickup date.');
  assert.equal(stepErrors(2, filled({ dobY: '2005', dobM: '11', dobD: '21' }), RULES, CTX).dob, undefined);
  assert.equal(stepErrors(2, filled({ email: 'rita@' }), RULES, CTX).email, 'Enter your email.');
  // an account made by phone may send a request before it has an email (the pay page asks for it)
  assert.equal(stepErrors(2, filled({ email: '' }), RULES, { ...CTX, signedInWithoutEmail: true }).email, undefined);
  assert.equal(stepErrors(2, filled({ phone: '555-0199' }), RULES, CTX).phone, 'Enter your mobile number with the area code.');
});

test('request: the coverage is chosen and agreed to, unless the car includes insurance', () => {
  assert.equal(stepErrors(3, filled({ coverage: '' }), RULES, CTX).coverage, 'Choose how the car is covered.');
  assert.equal(stepErrors(3, filled({ coverage: '1' }), RULES, CTX).opcfAck, 'Tick that you will upload your policy with OPCF 27.');
  assert.deepEqual(stepErrors(3, filled({ coverage: '1', opcfAck: true }), RULES, CTX), {});
  assert.deepEqual(stepErrors(3, filled({ coverage: '' }), RULES, { ...CTX, insuranceIncluded: true }), {});
  assert.equal(stepErrors(3, filled({ agree: false }), RULES, CTX).agree, 'Tick the box to agree before sending.');
  assert.equal(stepErrors(3, filled({ promo: 'SAVE 10!' }), RULES, CTX).promo, 'A promo code has letters, numbers and dashes only.');
});

test('request: what is sent is the site\'s own request, with nothing the phone did not ask left undefined', () => {
  const d = requestData(filled({ email: ' Rita@Example.Test ', coverage: '1', opcfAck: true, pickupAt: 'airport', pickupAirport: 'YYZ' }));
  assert.equal(d.email, 'rita@example.test');
  assert.equal(d.pickupAirport, 'YYZ');
  assert.equal(d.returnAirport, '');
  assert.equal(d.opcfAck, true);
  assert.deepEqual(d.drivers, []);
  assert.deepEqual(d.pickupAddress, { label: '', placeId: '' });
  assert.ok(Object.values(d).every((v) => v !== undefined));
  assert.equal(requestData(filled({ coverage: '3', opcfAck: true })).opcfAck, false);
  assert.match(requestKey('3f2c1a9e-77aa-4b0e-9c1d-000000000001'), /^[A-Za-z0-9-]{8,100}$/);
});

// ---------------------------------------------------------------- trips
const trip = (o: Record<string, unknown>) => ({ booking_number: 'CC-1042', status: 'confirmed', pickup_at: '2026-11-21T15:00:00Z', return_at: '2026-11-24T15:00:00Z', ...o });
test('trip: the one button follows what the server says is next, and goes where the button of the site goes', () => {
  assert.equal(nextStep(trip({ status: 'offered', sign_pay: { step: 'offer', due_cents: 0 } })).key, 'offer');
  assert.deepEqual(nextStep(trip({ status: 'pending_payment', sign_pay: { step: 'sign', due_cents: 30000 } })), { key: 'sign', title: 'Sign your rental agreement', cta: 'Read and sign', path: '/account/bookings/CC-1042/checkout' });
  assert.match(nextStep(trip({ status: 'pending_payment', sign_pay: { step: 'sign', due_cents: 30000, stale: true } })).title, /updated agreement/);
  assert.equal(nextStep(trip({ status: 'pending_payment', sign_pay: { step: 'drivers', due_cents: 30000 } })).cta, null);
  assert.equal(nextStep(trip({ status: 'pending_payment', sign_pay: { step: 'pay', due_cents: 30000 } })).path, '/account/bookings/CC-1042/checkout#pay');
  const need = { complete: false, items: [
    { key: 'dob', label: 'Your date of birth', status: 'done' as const, reason: null, action: null },
    { key: 'address', label: 'Your home address', status: 'missing' as const, reason: null, action: { label: 'Add it', path: '/account/profile' } },
    { key: 'licence', label: 'Your driver\'s licence', status: 'rejected' as const, reason: 'Blurry', action: { label: 'Take it again', path: '/account/bookings/CC-1042/verify' } },
    { key: 'review', label: 'Your selfie', status: 'review' as const, reason: null, action: null }] };
  // what was not accepted comes before what is missing
  assert.deepEqual(nextStep(trip({ still_needed: need })), { key: 'need', title: 'Not accepted: Your driver\'s licence', cta: 'Take it again', path: '/account/bookings/CC-1042/verify' });
  assert.equal(nextStep(trip({ still_needed: { ...need, items: need.items.slice(0, 2) } })).title, 'Your home address');
  assert.equal(nextStep(trip({ still_needed: { complete: false, items: [need.items[3]!] } })).key, 'none');
  assert.equal(nextStep(trip({}), { selfCheckin: true }).path, '/account/bookings/CC-1042/pickup');
  assert.equal(nextStep(trip({})).key, 'none');
  assert.equal(nextStep(trip({ status: 'on_rent' })).key, 'extend');
  assert.equal(nextStep(trip({ status: 'closed', still_needed: need })).key, 'none');
  // every address a next step gives is one the app opens as a screen
  for (const t of [trip({ status: 'pending_payment', sign_pay: { step: 'sign', due_cents: 1 } }), trip({ status: 'pending_payment', sign_pay: { step: 'pay', due_cents: 1 } }), trip({ still_needed: need }), trip({ status: 'on_rent' })]) {
    assert.equal(targetFor(nextStep(t).path)?.kind, 'screen', nextStep(t).path ?? '');
  }
  assert.deepEqual(targetFor(nextStep(trip({}), { selfCheckin: true }).path), { kind: 'screen', href: '/trip/CC-1042/checkin' });
});
test('trips: on trip first, then upcoming by pickup, then past newest first', () => {
  const list = [{ status: 'closed', pickup_at: '2026-01-01' }, { status: 'confirmed', pickup_at: '2026-12-01' }, { status: 'on_rent', pickup_at: '2026-11-19' }, { status: 'requested', pickup_at: '2026-11-25' }, { status: 'cancelled', pickup_at: '2026-06-01' }];
  const s = sortTrips(list);
  assert.deepEqual(s.current.map((b) => b.status), ['on_rent', 'requested', 'confirmed']);
  assert.deepEqual(s.past.map((b) => b.status), ['cancelled', 'closed']);
});

// ---------------------------------------------------------------- signing
const view = (o: Partial<EsignView> = {}): EsignView => ({ id: 's1', signer_name: 'Rita Renter', channels: [{ channel: 'sms', to: '(647) •••-••99' }], code_sent_to: null, verified: false, viewed: false, code_required: false,
  required_initials: ['km', 'fuel'], required_consents: ['esign', 'erecords', 'card'], initials: [], consents: [], signature: null, typed_fallback_allowed: true, signed: false, ready: false, ...o });
test('signing: one step at a time, in the order the site asks, and the code only when Program settings ask for it', () => {
  assert.equal(stageOf(view()), 'read');
  assert.equal(stageOf(view({ code_required: true })), 'code');
  assert.equal(stageOf(view({ code_required: true, verified: true })), 'read');
  assert.equal(stageOf(view({ viewed: true })), 'initials');
  assert.deepEqual(initialsLeft(view({ viewed: true, initials: ['km'] })), ['fuel']);
  assert.equal(stageOf(view({ viewed: true, initials: ['km', 'fuel'] })), 'consents');
  assert.deepEqual(consentsLeft(view({ consents: ['esign'] })), ['erecords', 'card']);
  assert.equal(stageOf(view({ viewed: true, initials: ['km', 'fuel'], consents: ['esign', 'erecords', 'card'] })), 'signature');
  assert.equal(stageOf(view({ viewed: true, initials: ['km', 'fuel'], consents: ['esign', 'erecords', 'card'], signature: 'drawn' })), 'ready');
  assert.equal(stageOf(view({ signed: true })), 'done');
  assert.deepEqual(progress(view({ viewed: true, initials: ['km'] })), { done: 2, total: 7 });
  assert.deepEqual(progress(view({ code_required: true, verified: true })), { done: 1, total: 8 });
  assert.equal(initialsOf(' rita marie  renter '), 'RMR');
});
