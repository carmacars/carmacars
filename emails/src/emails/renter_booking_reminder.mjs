import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_booking_reminder',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Hourly reminders job: booking status is confirmed and the pickup time is 24 hours away. Sent once. (Message template T5.)',
  timing: '24 hours before pickup',
  source: 'T5',
  subject: 'Tomorrow: your {{vehicle_name}} at {{pickup_time}}',
  preheader: 'Bring your original licence and the card ending {{card_last4}}.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Pickup tomorrow', 'See you tomorrow at {{pickup_time}}', 'Your {{vehicle_name}} will be clean, fuelled and ready, {{first_name}}.'),
    keyfacts(
      { label: 'When', value: '{{pickup_date}}', sub: '{{pickup_time}}' },
      { label: 'Where', value: '{{pickup_place}}' },
    ),
    h('Bring these'),
    list(
      'Your **original driver\'s licence**',
      'The **physical card ending {{card_last4}}**, in your name',
    ),
    notice('info', 'Deposit', 'A {{deposit_amount}} security deposit is taken on that card before we hand over the keys.'),
    when('verification_pending', [
      notice('alert', 'Your documents are not complete', 'Still missing: {{missing_items}}. Upload them today or we cannot release the car.'),
      button('Finish my documents', '@booking_verify'),
    ], [
      button('View pickup details', '@booking_pickup'),
    ]),
    small('If you are running late or need to change the time, reply to this email or call us before your pickup time.'),
  ],
  allowButtons: true,
  sample: { verification_pending: false, missing_items: 'proof of coverage' },
};
