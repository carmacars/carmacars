import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_return_complete',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Booking status changes to returned (keys taken, return condition report signed).',
  timing: 'Immediate',
  subject: 'Returned. Thanks for renting the {{vehicle_name}}',
  preheader: 'Checked in at {{checkin_time}}. Your statement follows within 7 business days.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Check-in complete', 'The car is back. Thank you, {{first_name}}.', 'We checked in the {{vehicle_name}} on {{checkin_date}} at {{checkin_time}}. Your signed return report is saved to your booking.'),
    facts(
      ['Odometer, out and in', '{{odometer_out}} to {{odometer_in}}'],
      ['Distance driven', '{{km_driven}} of {{km_allowance}} included'],
      ['Fuel or charge, out and in', '{{fuel_out}} to {{fuel_in}}'],
      ['Noted at return', '{{return_findings}}'],
    ),
    h('What happens next'),
    steps(
      ['We review the photos', 'If we find damage that was not visible at hand-back, we tell you within 48 hours, with photos.'],
      ['You get an itemized statement', 'Within 7 business days, with the record for every line.'],
      ['Your deposit is released', 'The {{deposit_amount}} deposit comes back within 7 business days of check-in, less any charges. Tolls and tickets can arrive later and are billed with a copy of the notice.'],
    ),
    button('View the return report', '@booking_condition_report'),
  ],
  sample: {
    checkin_date: 'Mon, Oct 26, 2026', checkin_time: '9:52 am', odometer_out: '18,240 km', odometer_in: '18,702 km',
    km_driven: '462 km', fuel_out: 'Full', fuel_in: 'Full', return_findings: 'Nothing to report',
  },
};
