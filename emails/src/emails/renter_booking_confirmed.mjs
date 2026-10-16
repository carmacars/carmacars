import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_booking_confirmed',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Booking status changes from pending_payment to confirmed (the offer was approved, the agreement signed, the booking total paid and the car still free for the dates).',
  timing: 'Immediate',
  subject: 'Confirmed: {{vehicle_name}}, {{pickup_date}}',
  preheader: 'Booking {{booking_number}}. {{amount_paid}} paid. Next: licence and coverage check.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Booking confirmed', 'You are booked, {{first_name}}', 'Your agreement is signed and your payment went through. The {{vehicle_name}} is yours for these dates.'),
    vehicle(),
    trip(),
    places(),
    price({ each: 'line_items', total: ['Paid', '{{amount_paid}}'] }),
    facts(
      ['Receipt no.', '{{receipt_number}}'],
      ['Card', '{{card_brand}} ending {{card_last4}}'],
      ['Kilometres included', '{{km_allowance}}, then {{overage_rate}} per km'],
      ['Security deposit', '{{deposit_amount}}, taken on this card at pickup'],
    ),
    when('needs_verification', [
      notice('alert', 'One step left before pickup', 'We need each driver\'s licence photos and a selfie, plus proof of coverage, by {{verify_by}}. No car is released without them.'),
      button('Upload licence and coverage', '@booking_verify'),
    ], [
      button('View my booking', '@booking'),
    ]),
    when('is_non_refundable', [
      small('This is a non-refundable booking. You saved {{non_refundable_percent}} on the rental charge, and it cannot be refunded if you cancel.'),
    ], [
      small('If your plans change, the refund depends on when we receive your cancellation. See the [cancellation policy](@cancellation_policy).'),
    ]),
  ],
  allowButtons: true,
  sample: { needs_verification: true, verify_by: 'Thu, Oct 22 at 10:00 am', is_non_refundable: false },
};
