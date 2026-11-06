import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_return_due',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Reminders job (every 5 minutes, migration 0430): the return time of a booking that is out has come and no return is recorded. Each one carries the renter\'s one-tap "I\'ve returned the car" link (migration 0532), and none is sent while the renter\'s report waits for staff. Sent once per return time, in the first 15 minutes (T13 follows at 15 minutes late). Only between 7 am and 10 pm Toronto time. Off with notify_return_due.',
  timing: 'At the return time',
  subject: 'Your booking ended at {{return_time}}',
  preheader: 'Please return the {{vehicle_name}} now, or extend if you need more time.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Return time', 'Your booking ended at {{return_time}}', 'Please bring the {{vehicle_name}} back to {{return_place}} now, {{first_name}}. If you are on your way, thank you.'),
    p('**{{extend_offer}}.** While you still have the car you can extend from your booking, and it costs less than being late.'),
    button('Extend my rental', '@booking_extend'),
    link('Already returned the car? Tell us in one tap', '{{returned_url}}'),
    p('Late fees start 30 minutes after the return time: {{late_fee_hourly}} per started hour, plus the rental charge for each extra day. To talk it through, call **{{support_phone}}**.'),
  ],
  sample: { returned_url: 'https://carmacars.ca/returned/9d3b6a1e-4c2f-4b7a-8e1d-2f6c5a4b3e21', late_fee_hourly: '$25', extend_offer: 'Extend at 5% off: from $107.35 for 1 more day' },
};
