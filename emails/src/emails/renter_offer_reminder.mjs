import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_offer_reminder',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Scheduled check: booking status is still offered and offer_expires_at is 6 hours away (for an offer window shorter than 12 hours, at the halfway point). Sent once per offer.',
  timing: '6 hours before the offer expires',
  subject: 'Your offer for the {{vehicle_name}} expires {{offer_expires_at}}',
  preheader: 'Approve, sign and pay {{total_amount}} to keep the car.',
  ref: 'Request {{booking_number}}',
  body: [
    hero('Offer expiring', 'Your offer ends in {{time_left}}', 'We are still holding the {{vehicle_name}} for you, {{first_name}}. The hold ends {{offer_expires_at}}.'),
    trip(),
    figure('Total to pay now', '{{total_amount}}', 'HST included. The {{deposit_amount}} security deposit is separate and taken at pickup.'),
    button('Approve and pay', '@booking_offer'),
    small('If the dates no longer work, [ask for a change](@booking_change). If you have changed your mind, do nothing and the offer will lapse. No charge either way.'),
  ],
  sample: { offer_expires_at: 'Wed, Oct 21 at 2:15 pm', time_left: '6 hours' },
};
