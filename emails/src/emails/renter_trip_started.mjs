import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_trip_started',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Reminders job (every 5 minutes, migration 0430): the pickup time of a confirmed booking passed 30 minutes ago (notify_pickup_unrecorded_minutes) and the handover was not recorded, so the rental-started email has not gone. The car is treated as out. Sent once per pickup time, never after renter_rental_started. Off with notify_trip_started.',
  timing: '30 minutes after the pickup time, when the handover was not recorded',
  subject: 'You\'re all set with the {{vehicle_name}}',
  preheader: 'Return by {{return_time}} on {{return_date}} at {{return_place}}.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Trip started', 'You\'re all set, {{first_name}}', 'Enjoy the {{vehicle_name}}. Here is what to keep in mind for your trip.'),
    button('View my trip', '@booking'),
    keyfacts(
      { label: 'Return by', value: '{{return_date}}', sub: '{{return_time}}' },
      { label: 'Return place', value: '{{return_place}}' },
    ),
    list(
      'Bring the car back with the same fuel or charge, and all keys.',
      'You have {{km_allowance}} included. Extra kilometres are {{overage_rate}} each.',
      'Only drivers named on the agreement may drive.',
      'Need more time? [Extend in your booking](@booking_extend): it is approved at once when the car is free.',
    ),
    notice('alert', 'Breakdown or accident', 'Call our 24-hour line at **{{roadside_phone}}**. If anyone is hurt, call 911 first.'),
    small('Your trip details are on your booking page any time.'),
  ],
  sample: {},
};
