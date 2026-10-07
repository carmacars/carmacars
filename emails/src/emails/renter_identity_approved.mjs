import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_identity_approved',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Every driver on a confirmed booking has identity_status verified and the booking coverage proof is marked confirmed (whichever happens last).',
  timing: 'Immediate',
  subject: 'You are verified. All set for {{pickup_date}}',
  preheader: 'Bring your original licence and the card ending {{card_last4}}.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Verified', 'Licence and coverage confirmed', 'Everything checks out, {{first_name}}. There is nothing more to send us before pickup.'),
    trip(),
    h('Bring these to pickup'),
    list(
      'Your **original driver\'s licence**. A photo or a copy is not accepted.',
      'The **physical {{card_brand}} card ending {{card_last4}}**. The {{deposit_amount}} deposit is taken on it before handover.',
    ),
    button('View my booking', '@booking'),
    small('We send the pickup details the day before.'),
  ],
};
