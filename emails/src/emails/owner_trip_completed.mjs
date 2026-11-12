import { hero, small, keyfacts, facts, notice, button, when } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_trip_completed',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'A standard or non-refundable booking on the owner\'s vehicle is returned (its status changes to returned: the car came back and was checked in), once per booking (2620, app.ntf_bookings_status_after). It replaces the booking-time emails owner_new_booking and owner_booking_confirmed, which are off since the owner\'s decision of November 12, 2026: many bookings are cancelled, so owners hear about a booking when it is complete. Sent only when the booking counts toward the owner\'s revenue (app.booking_counts_for_owner, 2480). Not sent for Owner Bookings or Turo trips, nor for a booking not shown to the owner (0156). show_amounts is false while the owner may not see the booking\'s revenue yet (hidden until the statement, 0156) and for a flat monthly pay car: the share is left out and the email says it shows on the next statement. has_km is true when the check-out and check-in odometers were both recorded.',
  timing: 'Immediate',
  subject: 'Trip complete: your {{vehicle_name}} is back',
  preheader: 'Booking {{booking_number}}: {{pickup_date}} to {{return_date}}.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Trip complete', 'Your {{vehicle_name}} is back', 'The trip is finished and the car was checked in, {{first_name}}.'),
    keyfacts(
      { label: 'Pickup', value: '{{pickup_date}}' },
      { label: 'Return', value: '{{return_date}}' },
    ),
    facts(
      ['Length', '{{billable_days}} days'],
      { label: 'Distance driven', value: '{{km_driven}}', when: 'has_km' },
      { label: 'Your share of this trip', value: '{{owner_share}}', when: 'show_amounts' },
    ),
    when('show_amounts', [
      notice('info', 'An estimate', 'Your share is worked out from the rental charge and your Revenue Share. Your monthly statement shows the final figures.'),
    ], [
      notice('info', 'Your share', 'The amount shows on your next statement.'),
    ]),
    button('View this trip', '@owner_booking'),
    small('We email you when a trip is complete and the car is back, not when a booking comes in. The bookings coming up are always in your owner portal.'),
  ],
  sample: {
    first_name: 'Daniel', vehicle_name: '2023 Toyota RAV4 XLE', km_driven: '412 km', has_km: true, owner_share: '$340.00', show_amounts: true,
  },
};
