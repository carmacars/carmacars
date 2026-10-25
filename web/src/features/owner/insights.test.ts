import { test } from 'node:test';
import assert from 'node:assert/strict';
import { liveStatus, monthStats, nextPayout, upcoming } from './insights.ts';
import type { OwnerBooking, OwnerVehicle } from './types.ts';

// The owner portal's figures (2026-10-24-owner-investor-portal-design.md): the owner's own bookings, invoices and
// statements, by month and by car; a rental over two months counts in each by rental day.
const car = (id: string, status = 'available'): OwnerVehicle => ({ vehicle_id: id, name: `Car ${id}`, plate: null, status, management_mode: 'managed', onboarding_status: 'enrolled',
  enrollment_date: null, exit_date: null, insurance_fee_cents: 45000, tracker_fee_cents: 2500, revenue_share_bps: 3500, listing_status: null, listing_path: null, estimate_cents: null,
  government_forms: null, next: null, checklist: null });
const bk = (id: string, v: string, a: string, z: string, cents: number, status = 'closed', type = 'standard'): OwnerBooking => ({ booking_id: id, booking_number: id, booking_type: type, status,
  vehicle_id: v, vehicle_name: `Car ${v}`, pickup_at: a, return_at: z, rental_charge_cents: cents, renter_name: null, renter_mobile: null });

test('months: rental charges by rental day, per car, fees and payouts', () => {
  const home = { vehicles: [car('a'), car('b')],
    invoices: [{ id: 'i', invoice_number: 'INV-1', vehicle_id: 'a', vehicle_name: 'Car a', kind: 'monthly' as const, period_month: '2026-10-01', billing_date: '2026-10-01', retry_on: null, status: 'paid',
      fees_cents: 47500, hst_cents: 6175, late_fee_cents: 0, total_cents: 53675, balance_cents: 0, paid_at: null, payment_method: 'pre_authorized_debit', pending: false, payable: false }],
    statements: [{ id: 's', statement_number: 'ST-1', statement_month: '2026-09-01', payout_date: '2026-10-15', status: 'approved', payout_cents: 50000 }] };
  const bookings = [
    bk('1', 'a', '2026-09-28T18:00:00Z', '2026-10-03T18:00:00Z', 50000), // 5 nights: 3 in September (28 to 30), 2 in October
    bk('2', 'b', '2026-10-10T18:00:00Z', '2026-10-12T18:00:00Z', 20000),
    bk('3', 'b', '2026-10-15T18:00:00Z', '2026-10-17T18:00:00Z', 99999, 'cancelled'),
    bk('4', 'a', '2026-10-20T18:00:00Z', '2026-10-22T18:00:00Z', 0, 'confirmed', 'owner')
  ];
  const m = monthStats(home, bookings, '2026-10-24', 2);
  assert.deepEqual(m.map((x) => x.key), ['2026-09', '2026-10']);
  assert.equal(m[0]!.rental_cents, 30000); assert.equal(m[0]!.days, 3); assert.equal(m[0]!.payout_cents, 50000);
  assert.equal(m[1]!.rental_cents, 40000); assert.equal(m[1]!.days, 4); assert.equal(m[1]!.bookings, 2); assert.equal(m[1]!.fees_cents, 47500); assert.equal(m[1]!.current, true);
  assert.deepEqual(m[1]!.cars.map((c) => [c.vehicle_id, c.days, c.rental_cents]), [['a', 2, 20000], ['b', 2, 20000]]);
});

test('live status, next payout and what is coming up', () => {
  const now = new Date('2026-10-24T15:00:00Z');
  const list = [bk('x', 'b', '2026-10-23T15:00:00Z', '2026-10-26T15:00:00Z', 1, 'confirmed'), bk('y', 'a', '2026-10-30T15:00:00Z', '2026-11-02T15:00:00Z', 1, 'confirmed')];
  assert.equal(liveStatus(car('a'), list, now).label, 'Available');
  assert.equal(liveStatus(car('b'), list, now).label, 'On rent');
  assert.equal(liveStatus(car('c', 'out_of_service'), list, now).label, 'In service');
  assert.equal(liveStatus({ ...car('d', 'onboarding'), onboarding_status: 'terms_set' }, list, now).key, 'onboarding');
  assert.deepEqual(upcoming(list, now).map((b) => b.booking_id), ['x', 'y']);
  assert.deepEqual(nextPayout({ statements: [{ id: 's', statement_number: 'ST-1', statement_month: '2026-09-01', payout_date: '2026-10-30', status: 'approved', payout_cents: 7 }], next_payout_date: '2026-11-15' }, '2026-10-24'), { date: '2026-10-30', cents: 7, statement_id: 's' });
  assert.deepEqual(nextPayout({ statements: [], next_payout_date: '2026-11-15' }, '2026-10-24'), { date: '2026-11-15', cents: null, statement_id: null });
});
