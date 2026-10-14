import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_change_proposal_expired',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Booking change job: a change waiting for the renter passed its deadline without being accepted. The change is closed as expired; the booking keeps its dates, car and price. Customer service is told at the same time.',
  timing: 'At the deadline',
  subject: 'Booking {{booking_number}} stays as it was',
  preheader: 'The suggested change was not accepted in time, so nothing changed.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('No change', 'Your booking stays as it was', 'The time to accept the change we suggested has passed, {{first_name}}. Nothing on your booking changed.'),
    compare('change_rows', 'Your booking', 'Not applied'),
    button('View your booking', '@booking'),
    small('Still want the change? Reply to this email or call us and we will check if the car is free.'),
  ],
  sample: {
    change_rows: [{ label: 'Return', before: 'Wed, Apr 7, 12:00 pm', after: 'Thu, Apr 8, 10:00 am' }],
  },
};
