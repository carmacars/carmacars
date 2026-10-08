import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_offer_expired',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'The offers-expire job (every 5 minutes, app.expire_offers) marks the current booking_offers row expired because offer_expires_at passed without approval. The booking becomes expired (the request is closed), and customer service gets an offer_expired task to reopen it with a new offer or leave it closed. Sent once per offer version.',
  timing: 'Immediate',
  subject: 'Your offer for the {{vehicle_name}} has expired',
  preheader: 'Nothing was charged. Your request is closed and our team will follow up with you.',
  ref: 'Request {{booking_number}}',
  body: [
    hero('Offer expired', 'This offer has ended', 'We did not receive your approval by {{offer_expires_at}}, so the offer for the {{vehicle_name}} has expired and your request is now closed. Nothing was booked or charged.'),
    trip(),
    p('Our team will follow up with you about this request. If you still need a car, reply to this email or open your request and we can reopen it with a fresh offer. The car, times or price may differ from the offer that expired.'),
    button('Open your request', '@booking_request'),
    small('If you no longer need a car, there is nothing to do.'),
  ],
  sample: { offer_expires_at: 'Wed, Oct 21 at 2:15 pm' },
};
