import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_late_return_final',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Reminders job (every 5 minutes): the booking is 2 hours past its return time (late_admin_minutes), still out (on rent, or confirmed with no handover recorded, migration 0430), with no paid extension, and T13 went at least 30 minutes ago. Between 7 am and 10 pm Toronto time; overnight it waits until 7 am. The late panel sends the same notice by hand, never twice. The deadline shown is 1 hour after this email is sent. (Message template T14.)',
  timing: '2 hours after the return time',
  source: 'T14',
  subject: 'Final notice: return the {{vehicle_name}} by {{final_deadline}}',
  preheader: 'The car is 2 hours overdue. Return it or pay for an extension now.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Final notice', 'The {{vehicle_name}} is 2 hours overdue', 'We have called and written, {{first_name}}. You now have until {{final_deadline}} to return the car or pay for an extension.'),
    figure('Deadline', '{{final_deadline}}', 'Return to {{return_place}}, or pay for an extension before then.'),
    notice('alert', 'After the deadline', 'We may end the rental, disable the car once it is parked, and recover it. Recovery costs are charged to you and there is no refund.'),
    button('Pay for an extension now', '@booking_extend'),
    p('Call **{{support_phone}}** right away if something has gone wrong. We would rather sort it out with you.'),
  ],
  sample: { final_deadline: '1:05 pm today' },
};
