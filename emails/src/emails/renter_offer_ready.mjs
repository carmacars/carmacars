import { hero, p, button, small, vehicle, keyfacts, price, compare, when, notice, facts, h } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_offer_ready',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Booking status changes to offered (staff reviewed the request and sent the offer). Also sent again when staff replace an open offer with a revised one.',
  timing: 'Immediate',
  subject: 'Your offer is ready: {{vehicle_name}}, {{pickup_date}}',
  preheader: 'Approve, sign and pay by {{offer_expires_at}} to confirm. Total {{total_amount}}.',
  ref: 'Request {{booking_number}}',
  sample: {
    has_adjustments: true,
    offer_note: 'The car comes back from another rental at 9:30, so we moved your pickup and return to 10:00. The price is unchanged.',
    adjustments: [
      { label: 'Pickup time', before: 'Fri, Oct 23, 9:00 am', after: 'Fri, Oct 23, 10:00 am' },
      { label: 'Return time', before: 'Mon, Oct 26, 9:00 am', after: 'Mon, Oct 26, 10:00 am' },
    ],
    offer_expires_at: 'Wed, Oct 21 at 2:15 pm',
  },
  body: [
    hero('Offer ready', 'Your car is available. Approve to confirm.', 'We reviewed your request, {{first_name}}. Nothing is booked or charged until you approve, sign and pay.'),
    vehicle(),
    keyfacts(
      { label: 'Pickup', value: '{{pickup_date}}', sub: '{{pickup_time}}' },
      { label: 'Return', value: '{{return_date}}', sub: '{{return_time}}' },
    ),
    when('has_adjustments', [
      notice('alert', 'We changed part of your request', '{{offer_note}}'),
      compare('adjustments'),
    ]),
    price({ each: 'line_items', total: ['Total to pay now', '{{total_amount}}'] }),
    facts(
      ['Pickup place', '{{pickup_place}}'],
      ['Return place', '{{return_place}}'],
      ['Kilometres included', '{{km_allowance}}, then {{overage_rate}} per km'],
      ['Security deposit', '{{deposit_amount}}, taken at pickup and separate from the total'],
    ),
    button('Review, approve and pay', '@booking_offer'),
    notice('info', 'This offer expires {{offer_expires_at}}', 'After that the car goes back on the calendar and you would need to send a new request.'),
    small('For different dates or another car, [ask for a change](@booking_change) before you approve. To pass on this offer, do nothing and it will lapse.'),
  ],
};
