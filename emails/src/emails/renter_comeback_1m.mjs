import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_comeback_1m',
  audience: 'renter',
  category: 'marketing',
  from: FROM.hello,
  digest: false,
  trigger: '30 days after booking status becomes closed, only if the renter\'s marketing consent is true, they have not unsubscribed, no booking or request was created since that booking closed, the renter is not blocked and has no unpaid balance. A new single-use discount code is generated at send time. This is the last automated offer for that booking.',
  timing: '30 days after the booking closes',
  subject: '{{discount_percent}}% off your next rental, {{first_name}}',
  preheader: 'Code {{discount_code}}, good until {{discount_expires}}.',
  ref: 'An offer for you',
  body: [
    hero('For your next trip', 'A car when you need one, {{discount_percent}}% off', 'It has been a month since you returned the {{last_vehicle_name}}, {{first_name}}. If a trip is coming up, this code is yours.'),
    figure('Your code', '{{discount_code}}', '{{discount_percent}}% off {{discount_applies_to}}. Book by {{discount_expires}}.'),
    button('See what is available', '@cars'),
    list(
      'Enter the code when you send your request. We apply it in our offer.',
      'One use, for you only.',
      'Same process as before: request, approve our offer, sign and pay.',
    ),
    small('This is the last offer we will send about your last rental.'),
  ],
  sample: { discount_percent: '15', discount_code: 'BACK15-MK7Q', discount_expires: 'Thu, Dec 31, 2026', discount_applies_to: 'the rental charge', last_vehicle_name: '2024 Honda Civic Sport' },
};
