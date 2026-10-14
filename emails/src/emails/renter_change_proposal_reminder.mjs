import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_change_proposal_reminder',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Booking change job (every 15 minutes): a change staff proposed (or a change the renter asked for and staff approved) has not been accepted, and its deadline is within booking_change_reminder_hours (Program settings, 12 by default). Sent once per change, and not when the change was made inside that window.',
  timing: 'Once, the reminder hours before the deadline',
  subject: 'Reminder: answer the change to booking {{booking_number}} by {{accept_by}}',
  preheader: 'If you do nothing, your booking stays as it is.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Reminder', 'Your answer is needed by {{accept_by}}', 'We are holding a change to your booking for you, {{first_name}}.'),
    compare('change_rows', 'Now', 'Suggested'),
    when('has_difference', [
      p('{{difference_label}}: **{{difference_amount}}** (HST included).'),
    ]),
    button('Review and answer', '@booking_change'),
    small('If you do not answer by {{accept_by}}, your booking stays exactly as it is.'),
  ],
  sample: {
    change_rows: [{ label: 'Pickup', before: 'Mon, Apr 5, 10:00 am', after: 'Mon, Apr 5, 2:00 pm' }],
    has_difference: false, difference_label: 'No change to the price', difference_amount: '$0.00', accept_by: 'Sat, Apr 3 at 10:00 am',
  },
};
