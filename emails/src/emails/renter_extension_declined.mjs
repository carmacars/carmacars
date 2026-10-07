import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_extension_declined',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Booking extension status changes from requested to declined. Staff choose the reason.',
  timing: 'Immediate',
  subject: 'We cannot extend booking {{booking_number}}',
  preheader: 'Please return the {{vehicle_name}} by {{return_time}} on {{return_date}}.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Extension declined', 'We cannot extend this rental', 'Sorry, {{first_name}}. The {{vehicle_name}} is due back at the original time.'),
    notice('info', 'Reason', '{{decline_reason}}'),
    keyfacts(
      { label: 'Return by', value: '{{return_date}}', sub: '{{return_time}}' },
      { label: 'Where', value: '{{return_place}}' },
    ),
    p('If you need a car for longer, reply to this email and we will check whether another car is free from your return time.'),
    button('View return details', '@booking_return'),
  ],
  sample: { decline_reason: 'Another renter has the car from the afternoon of your return day.' },
};
