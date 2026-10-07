import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_request_received',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'A booking row is created with status requested (booking event requested; the renter submitted the request form).',
  timing: 'Immediate',
  subject: 'We have your request for the {{vehicle_name}}',
  preheader: 'Nothing is booked or charged yet. We will reply with a firm offer.',
  ref: 'Request {{booking_number}}',
  body: [
    hero('Request received', 'We have your request, {{first_name}}', 'A person on our team is checking the car and your dates now. Nothing is booked and no card has been taken.'),
    vehicle(),
    trip(),
    facts(
      ['Pickup place', '{{pickup_place}}'],
      ['Return place', '{{return_place}}'],
      ['Estimate', '{{estimate_amount}} with HST. We confirm the firm price in our offer.'],
    ),
    h('What happens next'),
    steps(
      ['We review your request', 'We check the car, the dates and the price. We may suggest a small change, such as a different pickup time.'],
      ['You get our offer by email', 'It shows the final price and anything we changed.'],
      ['You approve, sign and pay', 'Only then is the car booked. Until then it is not held, and another renter can book it first. A security deposit hold is taken later, at pickup.'],
    ),
    button('View my request', '@booking_request'),
    small('To save time at pickup, you can upload your licence photos and a selfie from the same page.'),
  ],
  sample: { estimate_amount: '$468.95' },
};
