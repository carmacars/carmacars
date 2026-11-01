import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_late_return_first',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Reminders job (every 5 minutes): the return time has passed, the booking is still out (on rent, or confirmed with its pickup time passed and no handover recorded, migration 0430) and no paid extension covers the time. Sent once per return time, 15 minutes late (notify_late_first_minutes; renter_return_due goes at the return time). Between 7 am and 10 pm Toronto time; overnight it waits until 7 am. The late panel sends the same notice by hand, never twice. (Message template T13.)',
  timing: '15 minutes after the return time',
  source: 'T13',
  subject: 'Your rental ended at {{return_time}}. Please return the car now',
  preheader: 'Return the {{vehicle_name}} or call {{support_phone}} to extend.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Return overdue', 'Your rental ended at {{return_time}}', 'We have not checked in the {{vehicle_name}} yet, {{first_name}}. Please return it now or call us to extend.'),
    facts(
      ['Was due', '{{return_date}}, {{return_time}}'],
      ['Return place', '{{return_place}}'],
    ),
    notice('alert', 'What it costs', 'Once you are more than 30 minutes late you owe the rental charge for each extra day, plus a late fee of {{late_fee_hourly}} per started hour counted from {{return_time}}.'),
    button('Pay for an extension', '@booking_extend'),
    p('To talk it through, call **{{support_phone}}** now. If you are already on your way, thank you. We will see you shortly.'),
  ],
  sample: { late_fee_hourly: '$25' },
};
