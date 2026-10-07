import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_change_request_declined',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Staff decline a change request. Sent when the change request status becomes declined; staff enter the reason.',
  timing: 'Immediate',
  subject: 'We cannot make that change to booking {{booking_number}}',
  preheader: 'Your booking stays exactly as it was.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Change not possible', 'We cannot make that change', 'Sorry, {{first_name}}. Your booking is unchanged and still stands.'),
    notice('info', 'Reason', '{{decline_reason}}'),
    vehicle(),
    trip(),
    button('View my booking', '@booking'),
    small('If the booking no longer works for you, you can cancel from the same page. The refund depends on how close you are to pickup. See the [cancellation policy](@cancellation_policy).'),
  ],
  sample: { decline_reason: 'The car has another booking starting on the day you asked to return it.' },
};
