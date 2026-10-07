import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_rental_started',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Booking status changes to on_rent (deposit taken, pickup condition report signed, keys handed over).',
  timing: 'Immediate',
  subject: 'Your rental has started. Condition report inside',
  preheader: 'Return by {{return_time}} on {{return_date}}. Keep the 24-hour number handy.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Rental started', 'The {{vehicle_name}} is yours. Drive safe.', 'You are checked in, {{first_name}}. Your signed condition report and the pickup photos are saved to your booking.'),
    keyfacts(
      { label: 'Return by', value: '{{return_date}}', sub: '{{return_time}}' },
      { label: 'Kilometres included', value: '{{km_allowance}}', sub: 'then {{overage_rate}} per km' },
    ),
    facts(
      ['Odometer at pickup', '{{odometer_out}}'],
      ['Fuel or charge at pickup', '{{fuel_out}}'],
      ['Deposit', '{{deposit_amount}} {{deposit_method}} on the card ending {{card_last4}}'],
      ['Return place', '{{return_place}}'],
    ),
    button('View the condition report', '@booking_condition_report'),
    p('Check the report today. If you spot a mark that is not on it, reply to this email with a photo right away.'),
    notice('alert', 'Breakdown or accident', 'Call our 24-hour line at **{{roadside_phone}}**. If anyone is hurt, call 911 first. Tell us about any accident within 24 hours.'),
    list(
      'Return the car with the same fuel or charge, and all keys.',
      'To keep the car longer, [ask for an extension](@booking_extend) before your return time.',
      'Only drivers named on the agreement may drive.',
    ),
  ],
  sample: { odometer_out: '18,240 km', fuel_out: 'Full', deposit_method: 'held' },
};
