import { test } from 'node:test';
import assert from 'node:assert/strict';
import { toWizardCar } from './wizard-car.ts';

test('the request form car from public.booking_car (0102)', () => {
  const c = toWizardCar({
    vehicle_id: 'v1', slug: '2021-kia-forte', make: 'Kia', model: 'Forte', year: null, trim: 'LX', name: 'Kia Forte LX, black', from_cents: 5500,
    daily_rate_cents: 6000, weekend_rate_cents: 6500, weekly_rate_cents: 38500, monthly_rate_cents: 150000, multi_day_rate_cents: 5800,
    insurance_included: true, no_credit_card: null, delivery_fee_cents: 5000, pickup_fee_cents: 4000, owner_location: false, allows_18_to_20: false,
    is_sample: false, cover: { path: 'a/b.jpg', alt: null }
  });
  assert.deepEqual(c, {
    slug: '2021-kia-forte', vehicleId: 'v1', name: 'Kia Forte', year: null, trim: 'LX', daily: 6000, weekend: 6500, weekly: 38500, monthly: 150000, multi: 5800,
    insuranceIncluded: true, noCreditCard: false, delivery: 5000, pickup: 4000, ownerLocation: false, allowsYoung: false, cover: { path: 'a/b.jpg', alt: '' }, from: 5500, isSample: false, planOffered: true
  });
});

test('1202: a car at the RentalCover cap offers no Protection Plan', () => {
  const base = { vehicle_id: 'v2', slug: 's', make: 'M', model: 'X', year: 2024, trim: null, name: 'M X', from_cents: 1, daily_rate_cents: 1, weekend_rate_cents: 1, weekly_rate_cents: 7,
    monthly_rate_cents: 30, delivery_fee_cents: 0, pickup_fee_cents: 0, owner_location: false, allows_18_to_20: false, cover: null };
  assert.equal(toWizardCar({ ...base, protection_plan_offered: false }).planOffered, false);
  assert.equal(toWizardCar(base).planOffered, true);
});
