import { test } from 'node:test';
import assert from 'node:assert/strict';
import { bookingMoney, bookingsHref, bucketOf, bucketParam, bucketTotals, firstBucket, nights, sortBookings, statusOf, timeline, windowFor } from './bookings.ts';
import type { OwnerBooking } from './types.ts';

// r48 ops: the owner's Bookings page: upcoming / on a trip / past, the money of each booking by what the owner may see
// (0156: full, booked, unavailable), a filter by car and a timeline.
const NOW = Date.parse('2026-11-20T17:00:00Z');
const DAY = 86_400_000;
const b = (id: string, from: number, to: number, o: Partial<OwnerBooking> = {}): OwnerBooking => ({ booking_id: id, booking_number: `CC-${id}`, booking_type: 'standard', status: 'confirmed', vehicle_id: 'car1', vehicle_name: '2023 Kia Forte',
  pickup_at: new Date(NOW + from * DAY).toISOString(), return_at: new Date(NOW + to * DAY).toISOString(), rental_charge_cents: 30000, renter_name: null, renter_mobile: null, owner_view: 'full', ...o });

test('every booking is in one place: on a trip, upcoming or past', () => {
  assert.equal(bucketOf(b('1', -1, 2, { status: 'on_rent' }), NOW), 'trip');
  assert.equal(bucketOf(b('2', -1, 2), NOW), 'trip', 'confirmed and its pickup time passed');
  assert.equal(bucketOf(b('3', -3, -1, { status: 'on_rent' }), NOW), 'trip', 'late back is still out');
  assert.equal(bucketOf(b('4', 2, 5), NOW), 'upcoming');
  assert.equal(bucketOf(b('5', 2, 5, { status: 'pending_payment' }), NOW), 'upcoming');
  assert.equal(bucketOf(b('6', -9, -5, { status: 'closed' }), NOW), 'past');
  assert.equal(bucketOf(b('7', 2, 5, { status: 'cancelled' }), NOW), 'past', 'a cancelled booking is over, whatever its dates');
  assert.equal(bucketOf(b('8', -9, -5), NOW), 'past', 'its dates passed');
});

test('the lists: trips by the return that comes first, upcoming by pickup, past newest first; filtered by car', () => {
  const list = [b('a', 9, 12), b('b', 2, 5), b('c', -1, 4, { status: 'on_rent' }), b('d', -2, 1, { status: 'on_rent' }), b('e', -20, -15, { status: 'closed' }), b('f', -9, -5, { status: 'closed' }), b('g', 3, 6, { vehicle_id: 'car2' })];
  const s = sortBookings(list, NOW);
  assert.deepEqual([s.trip.map((x) => x.booking_id), s.upcoming.map((x) => x.booking_id), s.past.map((x) => x.booking_id)], [['d', 'c'], ['b', 'g', 'a'], ['f', 'e']]);
  assert.deepEqual(sortBookings(list, NOW, 'car2').upcoming.map((x) => x.booking_id), ['g']);
  assert.equal(firstBucket(s), 'trip');
  assert.equal(firstBucket(sortBookings(list, NOW, 'car2')), 'upcoming');
  assert.equal(firstBucket(sortBookings([], NOW)), 'past');
  assert.equal(bucketParam('trip'), 'trip'); assert.equal(bucketParam('x'), null); assert.equal(bucketParam(undefined), null);
  assert.equal(bookingsHref({ when: 'past', car: 'car2' }), '/owner/vehicles?tab=bookings&when=past&car=car2');
  assert.equal(bookingsHref({}), '/owner/vehicles?tab=bookings');
});

test('money follows what the owner may see: the amount, "with your statement", nothing for Unavailable, no charge for their own', () => {
  assert.deepEqual(bookingMoney(b('1', 1, 4)), { kind: 'amount', cents: 30000, label: 'Rental charge', note: 'Before tax; your share is on your statement' });
  const held = bookingMoney(b('2', 1, 4, { owner_view: 'booked', rental_charge_cents: null }));
  assert.deepEqual([held.kind, held.cents, held.label], ['statement', null, 'Booked']);
  // the database leaves the amount out: it is never shown, whatever the view says
  assert.equal(bookingMoney(b('3', 1, 4, { owner_view: 'full', rental_charge_cents: null })).kind, 'statement');
  const hidden = bookingMoney(b('4', 1, 4, { owner_view: 'unavailable', rental_charge_cents: 99999 }));
  assert.deepEqual([hidden.kind, hidden.cents, hidden.label], ['none', null, 'Unavailable']);
  assert.equal(bookingMoney(b('5', 1, 4, { booking_type: 'owner', rental_charge_cents: 0 })).kind, 'own');
});

test('totals add up only the amounts shown; hidden bookings count nowhere, held ones are "to come"', () => {
  const t = bucketTotals([b('1', 1, 4), b('2', 5, 7, { rental_charge_cents: 20000 }), b('3', 8, 9, { owner_view: 'booked', rental_charge_cents: null }),
    b('4', 10, 12, { owner_view: 'unavailable', rental_charge_cents: 50000 }), b('5', 1, 3, { status: 'cancelled' }), b('6', 13, 14, { booking_type: 'owner', rental_charge_cents: 0 })]);
  assert.deepEqual(t, { bookings: 4, days: 3 + 2 + 1 + 1, cents: 50000, shown: 2, onStatement: 1 });
  assert.equal(nights(b('x', 0, 0.2)), 1);
});

test('status in the owner\'s words; a booking not shown to them only says Unavailable', () => {
  assert.deepEqual(statusOf(b('1', -1, 2, { status: 'on_rent' })), { label: 'On rent now', tone: 'live' });
  assert.deepEqual(statusOf(b('2', 1, 2, { status: 'closed' })), { label: 'Completed', tone: 'ready' });
  assert.deepEqual(statusOf(b('3', 1, 2, { status: 'on_rent', owner_view: 'unavailable' })), { label: 'Unavailable', tone: 'muted' });
  assert.equal(statusOf(b('4', 1, 2, { status: 'pending_payment' })).label, 'Booked, payment due');
});

test('the timeline: a row a car, a bar a booking by percent of the six weeks, cut at the edges, today marked', () => {
  const start = Date.parse('2026-11-20T05:00:00Z');
  const w = windowFor('upcoming', start);
  assert.deepEqual(w, { from: start - 2 * DAY, days: 42 });
  assert.deepEqual(windowFor('past', start), { from: start - 41 * DAY, days: 42 });
  const tl = timeline([b('a', -5, 1, { status: 'on_rent' }), b('b', 3, 6), b('c', 38, 60), b('d', 2, 4, { status: 'cancelled' }), b('e', 8, 9, { owner_view: 'unavailable', booking_number: null }), b('f', 3, 6, { vehicle_id: 'car2', booking_type: 'owner' })],
    [{ vehicle_id: 'car1', name: 'Forte' }, { vehicle_id: 'car2', name: 'Jetta' }, { vehicle_id: 'car3', name: 'Free one' }], w.from, w.days, NOW);
  assert.equal(tl.rows.length, 3);
  const [r1, r2, r3] = tl.rows;
  assert.deepEqual(r1!.bars.map((x) => [x.id, x.kind]), [['a', 'trip'], ['b', 'upcoming'], ['e', 'unavailable'], ['c', 'upcoming']]);
  assert.deepEqual([r1!.bars[0]!.left, r1!.bars[0]!.clippedStart], [0, true]);
  assert.equal(r1!.bars[3]!.clippedEnd, true);
  for (const x of r1!.bars) assert.ok(x.left >= 0 && x.left + x.width <= 100.01, `${x.id} inside`);
  assert.match(r1!.bars[2]!.title, /^Unavailable: /);
  assert.deepEqual(r2!.bars.map((x) => x.kind), ['own']);
  assert.deepEqual(r3!.bars, [], 'a free car keeps its row');
  assert.ok(tl.today !== null && tl.today > 5 && tl.today < 7, `today at ${tl.today}%`);
  assert.equal(tl.weeks.length, 6);
  assert.equal(timeline([], [], w.from, w.days, NOW + 90 * DAY).today, null);
});
