import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_offer_approved_paid',
  audience: 'staff_va_cs',
  also: ['staff_va_fleet'],
  category: 'transactional',
  from: FROM.bookings,
  digest: true,
  digestSlot: 'next',
  trigger: 'Booking status changes from pending_payment to confirmed (offer approved, agreement signed, total paid). Queued for the next digest of customer service and fleet. Sent immediately instead when the pickup is less than 24 hours away.',
  timing: 'Next digest. Immediate if pickup is within 24 hours',
  subject: 'Confirmed and paid: {{booking_number}}, {{vehicle_name}}, {{pickup_date}}',
  preheader: '{{renter_name}} paid {{amount_paid}}. Start verification and plan the handover.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Offer approved and paid', 'Booking {{booking_number}} is confirmed', '{{renter_name}} approved the offer, signed and paid {{amount_paid}}. The calendar is blocked.'),
    keyfacts(
      { label: 'Pickup', value: '{{pickup_date}}', sub: '{{pickup_time}}' },
      { label: 'Return', value: '{{return_date}}', sub: '{{return_time}}' },
    ),
    facts(
      ['Vehicle', '{{vehicle_name}}, plate {{vehicle_plate}}'],
      ['Pickup place', '{{pickup_place}}'],
      ['Verification', '{{identity_summary}}'],
      ['Coverage', '{{coverage_summary}}'],
    ),
    button('Open the booking', '@va_cs_booking'),
    list(
      '**Customer service:** complete licence and coverage verification at least 24 hours before pickup.',
      '**Fleet:** assign the pickup and return jobs and check the car is clean for the day.',
    ),
  ],
  sample: { identity_summary: '1 driver, documents uploaded, not reviewed', coverage_summary: 'No proof yet' },
};
