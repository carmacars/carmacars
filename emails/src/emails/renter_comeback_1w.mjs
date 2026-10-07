import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_comeback_1w',
  audience: 'renter',
  category: 'marketing',
  from: FROM.hello,
  digest: false,
  trigger: '7 days after booking status becomes closed, only if the renter\'s marketing consent is true, they have not unsubscribed, no future booking or open request exists, the renter is not blocked and has no unpaid balance. A single-use discount code is generated for the renter at send time.',
  timing: '7 days after the booking closes',
  subject: '{{discount_percent}}% off your next CarmaCars rental',
  preheader: 'Code {{discount_code}}, good until {{discount_expires}}.',
  ref: 'An offer for you',
  body: [
    hero('Welcome back offer', '{{discount_percent}}% off your next rental', 'Thanks for renting with us last week, {{first_name}}. Here is a code for the next time you need a car.'),
    figure('Your code', '{{discount_code}}', '{{discount_percent}}% off {{discount_applies_to}}. Book by {{discount_expires}}.'),
    button('Choose a car', '@cars'),
    list(
      'Enter the code when you send your request. We apply it in our offer.',
      'One use, for you only.',
      'Same process as before: request, approve our offer, sign and pay.',
    ),
  ],
  sample: { discount_percent: '10', discount_code: 'BACK10-MK7Q', discount_expires: 'Mon, Nov 30, 2026', discount_applies_to: 'the rental charge' },
};
