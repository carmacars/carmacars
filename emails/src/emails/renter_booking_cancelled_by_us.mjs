import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_booking_cancelled_by_us',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Booking status changes from confirmed to cancelled with a booking cancellation row where the cancelling party is CarmaCars (no car or accepted substitute), or where the reason is that a driver could not be verified. The refund is 100%, including non-refundable bookings.',
  timing: 'Immediate',
  subject: 'We have had to cancel booking {{booking_number}}. Full refund',
  preheader: '{{refund_amount}} is going back to your card. We are sorry.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Cancelled by us', 'We have had to cancel your booking', 'We are sorry, {{first_name}}. We cannot provide the {{vehicle_name}} for {{pickup_date}}, and you are refunded in full.'),
    notice('info', 'Reason', '{{cancel_reason}}'),
    figure('Full refund', '{{refund_amount}}', 'Everything you paid at booking. Any deposit already taken is also returned in full.'),
    p('The refund goes to the card you paid with, within {{refund_days}} business days. Your bank may take longer to show it.'),
    button('See other cars for your dates', '@cars'),
    p('If you still need a car, reply to this email or call us. We will look for one that fits and put your request first.'),
  ],
  sample: { cancel_reason: 'The car was damaged on its previous rental and will not be repaired in time.', refund_amount: '$468.95' },
};
