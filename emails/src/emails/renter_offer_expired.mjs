import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_offer_expired',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Booking status changes from offered to expired (offer_expires_at passed without approval and payment).',
  timing: 'Immediate',
  subject: 'Your offer for the {{vehicle_name}} has expired',
  preheader: 'Nothing was charged. You can send a new request any time.',
  ref: 'Request {{booking_number}}',
  body: [
    hero('Offer expired', 'This offer has ended', 'We did not receive your approval by {{offer_expires_at}}, so the {{vehicle_name}} is back on the calendar. Nothing was charged.'),
    trip(),
    p('If you still need a car for these dates, send a new request and we will check what is available. The price may differ from the offer that lapsed.'),
    button('Send a new request', '@cars'),
  ],
  sample: { offer_expires_at: 'Wed, Oct 21 at 2:15 pm' },
};
