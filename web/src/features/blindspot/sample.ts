// A made-up booking for the Admin's preview of the Blind Spot agreement (Admin > Settings > Forms) and for the tests:
// no real person, the CarmaCars mailing address and HST number come from the settings passed in.
// Relative imports with their extension: the unit tests run this file in Node directly.
import type { BlindSpotFacts } from './layout.ts';

export function sampleFacts(extra: Pick<BlindSpotFacts['extra'], 'mailing' | 'hst_number'>, o: { insurer?: boolean } = {}): BlindSpotFacts {
  return {
    booking: {
      booking_number: 'CC-10001', agreement_number: 'RA-20001', pickup_at: '2027-06-16T14:00:00Z', return_at: '2027-06-19T14:00:00Z', billable_days: 3,
      rate_applied: 'daily', daily_rate_cents: 9900, weekend_rate_cents: 13500, weekly_rate_cents: 62000, monthly_rate_cents: 205000, multi_day_rate_cents: null,
      rental_charge_cents: 29700, km_allowance_per_day: 200, km_allowance_total: 600, overage_cents_per_km: 40, deposit_cents: 100000,
      subtotal_at_booking_cents: 41700, hst_at_booking_cents: 5421, total_due_at_booking_cents: 47121, coverage_option: o.insurer ? null : 2
    },
    renter: { legal_name: 'Jordan Sample Renter', date_of_birth: '2002-03-14', mobile: '+14165550142', address_line1: '100 Example Street', address_line2: 'Apt 1204',
      city: 'Toronto', province: 'ON', postal_code: 'M5H2N2' },
    drivers: [
      { role: 'renter', full_name: 'Jordan Sample Renter', date_of_birth: '2002-03-14', licence_number: 'S1234-56789-02314', licence_issuer: 'ON', licence_expiry: '2029-03-14' },
      { role: 'additional', full_name: 'Casey Example Driver', date_of_birth: '1990-07-01', licence_number: 'E1234-56789-00701', licence_issuer: 'ON', licence_expiry: '2028-07-01' }
    ],
    vehicle: { year: 2023, make: 'Mercedes-Benz', model: 'C-Class', trim: 'C 300 4MATIC', plate: 'SMPL123' },
    lines: [
      { charge_type: 'rental_charge', description: 'Rental charge', amount_cents: 29700 },
      { charge_type: 'young_driver_21_25', description: 'Young driver, 21 to 25', amount_cents: 4500 },
      { charge_type: 'coverage_sold', description: 'CarmaCars Protection Plan', amount_cents: 6000 },
      { charge_type: 'delivery', description: 'Delivery', amount_cents: 1500 }
    ],
    card: { brand: 'visa', last4: '4242' },
    extra: {
      ...extra, fleet_number: 'F-07', odometer_out_km: null,
      // 0178: card coverage, as most renters have it (boxes 12 and 13)
      coverage: o.insurer ? null : { coverage_option: 2, insurer_name: null, policy_number: null, policy_expiry: null, card_issuer: 'Visa', card_last4: '4242', coverage_provider: 'Assurant' },
      insurer: o.insurer ? { name: 'Example Mutual Insurance', claim_number: 'CLM-0000-1234', adjuster_name: 'Pat Adjuster', adjuster_phone: '4165550199', authorized_days: 3, authorized_daily_rate_cents: 9900 } : null
    }
  };
}
