import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_request_declined',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Booking status changes from requested to declined. Staff choose a reason; it fills decline_reason.',
  timing: 'Immediate',
  subject: 'We cannot fill your request for {{pickup_date}}',
  preheader: 'Nothing was charged. Here is why, and what you can do.',
  ref: 'Request {{booking_number}}',
  body: [
    hero('Request declined', 'We cannot fill this request', 'Sorry, {{first_name}}. We are not able to offer the {{vehicle_name}} for your dates. Nothing was booked or charged.'),
    notice('info', 'Reason', '{{decline_reason}}'),
    trip(),
    p('Other cars may be free for the same dates. Take a look, or reply to this email and tell us what you need. We will check for you.'),
    button('See available cars', '@cars'),
  ],
  sample: { decline_reason: 'The car is already booked for part of those dates.' },
};
