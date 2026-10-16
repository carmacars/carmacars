import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_booking_confirmed',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'A booking of type owner (an Owner Booking: the owner driving their own vehicle) changes to confirmed, after the owner signs the Owner Rental agreement and staff confirm the licence is valid.',
  timing: 'Immediate',
  subject: 'Confirmed: your own booking of the {{vehicle_name}}, {{pickup_date}}',
  preheader: 'No rental charge or deposit. Booking {{booking_number}}.',
  ref: 'Owner Booking {{booking_number}}',
  body: [
    hero('Owner Booking confirmed', 'Your car is reserved for you', 'The {{vehicle_name}} is blocked for these dates, {{first_name}}. No renter can book over them.'),
    keyfacts(
      { label: 'Pickup', value: '{{pickup_date}}', sub: '{{pickup_time}}' },
      { label: 'Return', value: '{{return_date}}', sub: '{{return_time}}' },
    ),
    facts(
      ['Pickup place', '{{pickup_place}}'],
      ['Return place', '{{return_place}}'],
      ['Rental charge, fees, deposit', 'None'],
    ),
    h('Good to know'),
    list(
      'Bring your driver\'s licence. We complete a condition report with photos at pickup and at return, the same as any rental.',
      'Tolls and tickets from these dates are billed to you at cost, with no administration fee.',
      'If you damage the car: under {{deductible_amount}} you repair it at your own cost. If a claim is made on the fleet policy, you pay the {{deductible_amount}} deductible.',
      'Your monthly fees continue as normal.',
    ),
    button('View this booking', '@owner_booking'),
    small('To change the dates, reply to this email. A renter\'s confirmed booking has priority, so ask early.'),
  ],
  sample: { pickup_place: 'CarmaCars lot, handed over by our field staff', return_place: 'CarmaCars lot' },
};
