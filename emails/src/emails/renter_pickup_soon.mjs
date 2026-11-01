import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_pickup_soon',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Reminders job (every 5 minutes, migration 0430): a confirmed booking whose pickup is about 2 hours away (Program settings, notify_pickup_soon_hours) and not yet handed over. Sent once per pickup time, so again after the pickup moves. Only between 7 am and 10 pm Toronto time; an earlier pickup has the day-before reminder only. Off with notify_pickup_soon.',
  timing: 'About 2 hours before pickup',
  subject: 'See you at {{pickup_time}} today: your {{vehicle_name}}',
  preheader: 'Bring your licence and the card ending {{card_last4}}.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Pickup soon', 'See you at {{pickup_time}} today', 'Your {{vehicle_name}} is almost ready, {{first_name}}.'),
    keyfacts(
      { label: 'When', value: '{{pickup_time}}', sub: '{{pickup_date}}' },
      { label: 'Where', value: '{{pickup_place}}' },
    ),
    h('Bring these'),
    list(
      'Your **original driver\'s licence**',
      'The **physical card ending {{card_last4}}**, in your name',
    ),
    button('View pickup details', '@booking_pickup'),
    when('verification_pending', [
      notice('alert', 'Your documents are not complete', 'Still missing: {{missing_items}}. [Upload them now](@booking_verify) so we can hand over the car on time.'),
    ]),
    small('Running late or need to change the time? Call us at {{support_phone}} before your pickup time.'),
  ],
  sample: { verification_pending: false, missing_items: 'proof of coverage', pickup_time: '2:00 pm' },
};
