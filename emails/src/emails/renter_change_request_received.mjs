import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_change_request_received',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'A booking change request row is created by the renter on a booking with status offered or confirmed.',
  timing: 'Immediate',
  subject: 'We have your change request for booking {{booking_number}}',
  preheader: 'Your current booking stays as it is until we reply.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Change requested', 'We are checking your change', 'Thanks, {{first_name}}. We will confirm whether the change is possible and what it does to the price.'),
    compare('requested_changes', 'Now', 'You asked for'),
    notice('info', 'Nothing has changed yet', 'Your {{current_state}} stays exactly as it is until you accept our reply. A change is never applied without your approval.'),
    button('View my booking', '@booking'),
    small('If your pickup is less than 24 hours away, call us as well so we see it in time.'),
  ],
  sample: {
    current_state: 'confirmed booking',
    requested_changes: [{ label: 'Return', before: 'Mon, Oct 26, 10:00 am', after: 'Tue, Oct 27, 10:00 am' }],
  },
};
