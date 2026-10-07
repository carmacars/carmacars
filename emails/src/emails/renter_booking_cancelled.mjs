import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_booking_cancelled',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Booking status changes from confirmed to cancelled or no_show with a booking cancellation row where cancelled_by is renter (the database computes the tier, percent and refund). (Message template T12.)',
  timing: 'Immediate',
  source: 'T12',
  subject: 'Booking {{booking_number}} is cancelled. Refund {{refund_amount}}',
  preheader: 'Received {{cancellation_received_at}}. {{refund_percent}} of {{amount_paid}} is refunded.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Booking cancelled', 'Your booking is cancelled', 'We received your cancellation on {{cancellation_received_at}}, {{first_name}}. The {{vehicle_name}} is released.'),
    figure('Your refund', '{{refund_amount}}', '{{refund_percent}} of the {{amount_paid}} you paid at booking.'),
    facts(
      ['Cancellation received', '{{cancellation_received_at}}'],
      ['Pickup was', '{{pickup_date}}, {{pickup_time}}'],
      ['Refund tier', '{{refund_tier}}'],
      ['Refund', '{{refund_percent}} of {{amount_paid}} = {{refund_amount}}'],
      ['Deposit', 'Any deposit already taken is returned in full'],
    ),
    when('has_refund', [
      p('The refund goes to the card you paid with, within 10 business days. Your bank may take longer to show it.'),
    ], [
      p('No refund is due under the policy for this booking, so nothing will be returned to your card.'),
    ]),
    button('See the cancellation policy', '@cancellation_policy'),
    small('The refund depends on when we receive the cancellation. The first row of the policy that fits applies. This does not limit any right you have under the Ontario Consumer Protection Act.'),
  ],
  sample: {
    cancellation_received_at: 'Tue, Oct 20, 2026 at 9:14 am', refund_percent: '75%', refund_amount: '$351.71',
    refund_tier: '48 hours or more before the start', has_refund: true,
  },
};
