import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_damage_found',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'An incident of type damage is recorded on a returned booking from the photo review after hand-back (damage not noted on the signed return report). Must be sent within 48 hours of check-in. (Message template T8.)',
  timing: 'Immediate, within 48 hours of return',
  source: 'T8',
  subject: 'Damage found on the {{vehicle_name}} after your return',
  preheader: 'Booking {{booking_number}}. Photos inside. An itemized statement will follow.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Inspection result', 'We found damage after your return', 'Our inspection of the {{vehicle_name}} on {{inspection_date}} found damage that is not on the pickup report, {{first_name}}.'),
    facts(
      ['Found', '{{damage_description}}'],
      ['Inspected', '{{inspection_date}}'],
      ['Checked in', '{{checkin_date}}, {{checkin_time}}'],
    ),
    button('View the photos', '{{supporting_document_url}}'),
    h('What happens next'),
    list(
      'We get an estimate from an approved shop.',
      'You receive an itemized statement with the estimate before anything is charged.',
      'If you have coverage for the rental, tell your insurer or card issuer now. They may have a deadline.',
    ),
    p('If you know how this happened, or believe it was there before, reply to this email with anything that helps. Photos from your rental are useful.'),
  ],
  sample: {
    inspection_date: 'Mon, Oct 26, 2026', damage_description: 'Scrape on the rear right bumper, about 20 cm (photos 14 and 15)',
    checkin_date: 'Mon, Oct 26, 2026', checkin_time: '9:52 am',
  },
};
