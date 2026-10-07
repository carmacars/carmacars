import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_late_return_first',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Late-returns job (every 5 minutes): the return time has passed, booking status is still on_rent and no paid extension covers the time. Sent once, at 0 minutes late. (Message template T13.)',
  timing: 'At the return time',
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
