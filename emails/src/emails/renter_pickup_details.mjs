import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_pickup_details',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'The pickup field job for a confirmed booking has an assigned staff member and the pickup is 3 hours away. Sent earlier, at once, if the job is assigned inside that window, and sent again if the place, time or staff member changes after sending.',
  timing: '3 hours before pickup',
  subject: 'Pickup today: {{field_staff_name}} meets you at {{pickup_time}}',
  preheader: '{{pickup_place}}. Allow a few minutes for the walk-around.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Pickup details', '{{field_staff_name}} will meet you at {{pickup_time}}', 'Here is everything for today\'s handover of the {{vehicle_name}}, {{first_name}}.'),
    vehicle('Plate {{vehicle_plate}}'),
    facts(
      ['When', '{{pickup_date}}, {{pickup_time}}'],
      ['Where', '{{pickup_place}}'],
      ['Who', '{{field_staff_name}}, CarmaCars'],
      { label: 'Meeting note', value: '{{meeting_note}}', when: 'meeting_note' },
    ),
    h('How the handover works'),
    steps(
      ['We check your licence and card', 'Bring your original licence and the physical card ending {{card_last4}}. We can only hand over to you in person.'],
      ['We take the deposit', '{{deposit_amount}} on that card, before the keys change hands.'],
      ['We walk around the car together', 'We record the odometer, fuel and any marks, with photos. You both sign the condition report.'],
    ),
    button('Open pickup details', '@booking_pickup'),
    small('If you are running late, call {{support_phone}} so we can tell the person meeting you.'),
  ],
  sample: { meeting_note: 'Meet at the taxi stand on the Front Street side.' },
};
