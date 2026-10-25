// A made-up booking with everything a rental agreement can carry (migration 0154), for the regression test of both
// agreements and the sample PDFs: two drivers, an insurance replacement rental, delivery, add-ons, a young driver, the
// Protection Plan, a cash deposit, paid by e-Transfer; then the same booking as picked up and as returned (late, over
// the kilometres, a quarter tank short, new damage). No real person: every name, number and address is invented.
// Relative imports with their extension: the unit tests run this file in Node directly.
import type { AgreementFacts } from './model.ts';
import type { AgreementExtra, Line } from './extra.ts';

export type Stage = 'open' | 'pickup' | 'return';
const V = { id: 'veh-1', year: 2023, make: 'Mercedes-Benz', model: 'C-Class', trim: 'C 300 4MATIC', colour: 'Black', fuel: 'gasoline', plate: 'SMPL123', vin: 'W1KAF4HB0PR000001', fleet_number: 'F-07' };
const BOOKING_LINES: Line[] = [
  { charge_type: 'rental_charge', description: 'Rental charge', amount_cents: 29700, hst_cents: 3861, stage: 'booking' },
  { charge_type: 'young_driver_21_25', description: 'Young driver, 21 to 25', amount_cents: 4500, hst_cents: 585, stage: 'booking' },
  { charge_type: 'coverage_sold', description: 'CarmaCars Protection Plan', amount_cents: 6000, hst_cents: 780, stage: 'booking' },
  { charge_type: 'delivery', description: 'Delivery', amount_cents: 1500, hst_cents: 195, stage: 'booking' },
  { charge_type: 'baby_seat', description: 'Baby seat', amount_cents: 3000, hst_cents: 390, stage: 'booking' },
  { charge_type: 'additional_driver', description: 'Additional driver: Casey Example Driver', amount_cents: 2000, hst_cents: 260, stage: 'booking' }
];
const RETURN_LINES: Line[] = [
  { charge_type: 'mileage_overage', description: 'Kilometres over: 200 km at $0.40', amount_cents: 8000, hst_cents: 1040, stage: 'check_in' },
  { charge_type: 'late_return_extra_days', description: 'Late return: 1 extra day', amount_cents: 9900, hst_cents: 1287, stage: 'check_in' },
  { charge_type: 'late_return_fee', description: 'Late return fee', amount_cents: 2500, hst_cents: 325, stage: 'check_in' },
  { charge_type: 'fuel', description: 'Fuel: 25% short', amount_cents: 2000, hst_cents: 260, stage: 'check_in' },
  { charge_type: 'fuel_service_fee', description: 'Fuel service fee', amount_cents: 1500, hst_cents: 195, stage: 'check_in' },
  { charge_type: 'cleaning', description: 'Cleaning', amount_cents: 5000, hst_cents: 650, stage: 'check_in' }
];
export const RICH = { subtotal: 46700, hst: 6071, total: 52771, deposit: 100000 };

export function richFacts(stage: Stage = 'open'): { f: AgreementFacts; x: AgreementExtra; bs: { mailing: { line: string; street: string; unit: string; city: string; province: string; postal_code: string }; hst_number: string; fleet_number: string; odometer_out_km: number | null; multi_day_rate_cents: null; insurer: { name: string; claim_number: string; adjuster_name: string; adjuster_phone: string; authorized_days: number; authorized_daily_rate_cents: number } } } {
  const f: AgreementFacts = {
    booking: {
      id: 'b-1', booking_number: 'CC-10077', agreement_number: 'RA-20077', booking_type: 'standard', booked_at: '2027-06-01T15:00:00Z', requested_at: '2027-06-01T14:00:00Z',
      pickup_at: '2027-06-16T14:00:00Z', return_at: '2027-06-19T14:00:00Z', pickup_place: '100 Example Street, Toronto', return_place: '100 Example Street, Toronto',
      pickup_method: 'delivered', return_method: 'picked_up', billable_days: 3, rate_applied: 'daily', daily_days: 3, weekend_days: 0,
      daily_rate_cents: 9900, weekend_rate_cents: 13500, weekly_rate_cents: 62000, monthly_rate_cents: 205000, rental_charge_cents: 29700,
      km_allowance_per_day: 200, km_allowance_total: 600, overage_cents_per_km: 40, deposit_cents: RICH.deposit, deductible_cents: 250000, coverage_option: 3,
      subtotal_at_booking_cents: RICH.subtotal, hst_at_booking_cents: RICH.hst, total_due_at_booking_cents: RICH.total, renter_due_at_booking_cents: RICH.total,
      offer_approved_version: 1, offer_approved_at: '2027-06-01T16:00:00Z', renews_booking_id: null
    },
    renter: { legal_name: 'Jordan Sample Renter', date_of_birth: '2003-03-14', mobile: '+14165550142', email: 'jordan.sample@example.test', address_line1: '100 Example Street',
      address_line2: 'Apt 1204', city: 'Toronto', province: 'ON', postal_code: 'M5H 2N2', country: 'CA' },
    drivers: [
      { id: 'bd-1', driver_id: 'd-1', role: 'renter', full_name: 'Jordan Sample Renter', date_of_birth: '2003-03-14', licence_number: 'S1234-56789-03314', licence_class: 'G', licence_issuer: 'ON', licence_expiry: '2029-03-14', identity_method: 'staff_review', identity_verified_on: '2027-06-10' },
      { id: 'bd-2', driver_id: 'd-2', role: 'additional', full_name: 'Casey Example Driver', date_of_birth: '1990-07-01', licence_number: 'E1234-56789-00701', licence_class: 'G', licence_issuer: 'ON', licence_expiry: '2028-07-01', identity_method: 'staff_review', identity_verified_on: '2027-06-10' }
    ],
    vehicle: { year: V.year, make: V.make, model: V.model, trim: V.trim, colour: V.colour, fuel: V.fuel, plate: V.plate, vin: V.vin },
    lines: BOOKING_LINES.map((l) => ({ charge_type: l.charge_type, description: l.description, amount_cents: l.amount_cents, hst_cents: l.hst_cents, stage: l.stage })),
    card: { brand: 'visa', last4: '4242', cardholder_name: 'Jordan Sample Renter' },
    coverage: { coverage_option: 3, insurer_name: null, policy_number: null, policy_expiry: null, card_issuer: null, card_last4: null, status: 'approved' },
    company: { legal_name: '18122211 Canada Inc.', trade_name: 'CarmaCars', email: 'rent@carmacars.ca', phone: '647-000-0000', address: '2967 Dundas St W, Unit 208B, Toronto, ON M6P 1Z2', incident_line: '647-000-0001', deductible_cents: 250000 }
  };
  const x: AgreementExtra = {
    booking: { status: stage === 'open' ? 'confirmed' : stage === 'pickup' ? 'on_rent' : 'returned', bill_to: 'insurer', payment_mode: 'offline', rental_pay_method: 'e_transfer', deposit_pay_method: 'cash',
      agreement_on_paper: false, handed_over_at: stage === 'open' ? null : '2027-06-16T14:20:00Z', checked_in_at: stage === 'return' ? '2027-06-19T16:40:00Z' : null },
    vehicle: V, original_vehicle: null, swaps: [],
    drivers: { 'bd-1': { address: '100 Example Street, Apt 1204, Toronto, ON M5H 2N2', mobile: '+14165550142', email: 'jordan.sample@example.test' },
      'bd-2': { address: '22 Sample Avenue, Toronto, ON M4M 1A1', mobile: '+14165550177', email: 'casey.example@example.test' } },
    deposit: { amount_cents: RICH.deposit, pay_method: 'cash', method: stage === 'open' ? null : 'offline', paid_method: stage === 'open' ? null : 'cash', status: stage === 'open' ? null : 'held',
      taken_at: stage === 'open' ? null : '2027-06-16T14:15:00Z', applied_cents: 0, released_cents: stage === 'return' ? 70000 : 0, held_back_cents: 0, card_hold_days: 7 },
    payments: [{ purpose: 'booking_total', kind: 'charge', method: 'e_transfer', amount_cents: RICH.total, card_brand: null, card_last4: null, reference: 'ET-0001', at: '2027-06-02T12:00:00Z' }],
    lines: stage === 'return' ? [...BOOKING_LINES, ...RETURN_LINES] : BOOKING_LINES,
    late: { fee_cents: 2500, cap_bps: 5000, grace_minutes: 59 },
    card_expiry: '08/2029', multi_day_rate_cents: null,
    insurer_policy: { policy_number: 'P-778899', province: 'ON', expiry: '2027-12-31', insured_vehicle: '2019 Honda Civic, plate ABCD123' },
    pickup: stage === 'open' ? null : { report_id: 'a1b2c3d4-0000-4000-8000-000000000001', completed: true, at: '2027-06-16T14:20:00Z', odometer_km: 20150, fuel_pct: 100, keys: 2, staff_user_id: 'u-staff',
      staff_name: 'Sam Staffer', damages: [{ label: 'D1', location: 'rear bumper', description: 'light scuff' }], photos: 19, vehicle: V },
    return: stage === 'return' ? { report_id: 'e5f6a7b8-0000-4000-8000-000000000002', at: '2027-06-19T16:40:00Z', odometer_km: 20950, odometer_out_km: 20150, km_driven: 800, km_allowed: 600, km_charged: 200,
      fuel_out_pct: 100, fuel_pct: 75, minutes_late: 160, late_hours: 3, extra_days: 1, keys: 2, cleanliness: 'cleaning', staff_user_id: 'u-staff2', staff_name: 'Riley Checker',
      new_damages: [{ label: 'D2', location: 'front left wheel', description: 'curb rash' }], photos: 19, vehicle: V } : null
  };
  const bs = {
    mailing: { line: '2967 Dundas St W, Unit 208B, Toronto, ON M6P 1Z2', street: '2967 Dundas St W', unit: '208B', city: 'Toronto', province: 'ON', postal_code: 'M6P 1Z2' },
    hst_number: '79878 1234 RT0001', fleet_number: V.fleet_number, odometer_out_km: stage === 'open' ? null : 20150, multi_day_rate_cents: null,
    insurer: { name: 'Example Mutual Insurance', claim_number: 'CLM-0000-1234', adjuster_name: 'Pat Adjuster', adjuster_phone: '4165550199', authorized_days: 3, authorized_daily_rate_cents: 9900 }
  };
  return { f, x, bs };
}
