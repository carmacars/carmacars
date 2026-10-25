import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_new_booking',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'A standard or non-refundable booking on the owner\'s vehicle changes to confirmed. Not sent for Owner Bookings or for Turo trips, nor for a booking not shown to the owner (0156). is_self_managed is true when the vehicle\'s management mode is Self-Managed; only then are the renter\'s name and mobile number included. show_amounts is false while staff hide the booking\'s revenue from the owner (until the return or the statement): the rental charge is left out.',
  timing: 'Immediate',
  subject: 'New booking on your {{vehicle_name}}: {{pickup_date}} to {{return_date}}',
  preheader: 'Booking {{booking_number}}: {{pickup_date}} to {{return_date}}.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('New booking', 'Your {{vehicle_name}} is booked', 'A renter has signed and paid, {{first_name}}. The dates are blocked on your calendar.'),
    keyfacts(
      { label: 'Pickup', value: '{{pickup_date}}', sub: '{{pickup_time}}' },
      { label: 'Return', value: '{{return_date}}', sub: '{{return_time}}' },
    ),
    facts(
      { label: 'Rental charge', value: '{{rental_charge}} before tax', when: 'show_amounts' },
      ['Length', '{{billable_days}} days'],
      { label: 'Renter', value: '{{renter_name}}, {{renter_phone}}', when: 'is_self_managed' },
    ),
    when('is_self_managed', [
      notice('info', 'You hand over this rental', 'Complete the condition report and the photo set at pickup and at return. We enable the car for the booked period only. Keep the renter\'s details confidential and use them only for this handover.'),
    ], [
      notice('info', 'During this rental', 'You keep live location. Your lock, alarm and shut-off controls are blocked from pickup until the car is checked in.'),
    ]),
    button('View this booking', '@owner_booking'),
    small('The rental counts toward your statement for the month it ends, once collected. Your statement shows the final figures.'),
  ],
  sample: {
    first_name: 'Daniel', vehicle_name: '2023 Toyota RAV4 XLE', rental_charge: '$340.00', is_self_managed: false, show_amounts: true,
    renter_name: '', renter_phone: '',
  },
};
