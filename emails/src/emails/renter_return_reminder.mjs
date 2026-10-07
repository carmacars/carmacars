import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_return_reminder',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Hourly reminders job: booking status is on_rent and the return time is 24 hours away. Sent once per return time, so it is sent again after an extension moves the return. (Message template T6.)',
  timing: '24 hours before return',
  source: 'T6',
  subject: 'Your rental ends tomorrow at {{return_time}}',
  preheader: 'Return to {{return_place}} with the same fuel and all keys.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Return tomorrow', 'Your rental ends tomorrow at {{return_time}}', 'Here is what to do so the return is quick, {{first_name}}.'),
    keyfacts(
      { label: 'When', value: '{{return_date}}', sub: '{{return_time}}' },
      { label: 'Where', value: '{{return_place}}' },
    ),
    h('Before you hand it back'),
    list(
      'Bring the fuel or charge back to the pickup level: **{{fuel_out}}**.',
      'Bring **all keys** and anything that came with the car.',
      'Take your belongings and leave the car reasonably clean.',
      'You have {{km_allowance}} included. Extra kilometres are {{overage_rate}} each.',
    ),
    button('Ask to extend my rental', '@booking_extend'),
    notice('info', 'Please be on time', 'An extension only counts once we confirm it in writing and it is paid before your return time. More than 30 minutes late, a late fee of {{late_fee_hourly}} per started hour applies, plus the rental charge for each extra day.'),
    small('We inspect the car with you at hand-back and you both sign the condition report.'),
  ],
  sample: { fuel_out: 'Full', late_fee_hourly: '$25' },
};
