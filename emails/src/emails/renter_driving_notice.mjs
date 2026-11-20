import { hero, p, facts, notice, button, small } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_driving_notice',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Tracker events are on (migration 3320) and the Tracker of a car out on this renter\'s rental recorded driving worth a friendly word, with no charge: a speed over the speeding alert level of Tracking settings (140 km/h by default) but not over 180 km/h, or several hard braking or acceleration events in the window. Once per event (one per car, kind and window). The renter may mute it in their notification settings.',
  timing: 'Immediate, once per event',
  subject: '{{event_title}}: your {{vehicle_name}}',
  preheader: '{{event_short}}',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('A friendly heads-up', '{{event_title}}', '{{event_what}}'),
    p('Hi {{first_name}}, a quick word about your rental, booking {{booking_number}}.'),
    facts(
      ['When', '{{event_when}}'],
      ['The charge', '{{event_fee}}'],
      ['The clause', '{{event_clause}}'],
    ),
    notice('info', 'What we ask', '{{event_ask}}'),
    button('Open my booking', '@booking'),
    p('Nothing to do and nothing to pay. We tell you early so it never becomes a charge. Questions? Call **{{support_phone}}**.'),
    small('You can turn these heads-up messages off in your notification settings. Notices about a charge are always sent.'),
  ],
  sample: {
    event_title: 'Please slow down',
    event_what: 'The Tracker in your 2024 Honda Civic Sport recorded 152 km/h on Sat, Nov 21, 2026 at 2:14 pm.',
    event_when: 'Sat, Nov 21, 2026 at 2:14 pm',
    event_fee: 'No charge this time. Over 180 km/h there is a speeding charge of $500.00 plus HST: one charge an event, at the highest limit reached.',
    event_clause: 'Rental agreement: 10.5 Speeding charges.',
    event_ask: 'Please ease off and keep to the limit. Thank you.',
    event_short: '152 km/h recorded. No charge this time. Please slow down.',
  },
};
