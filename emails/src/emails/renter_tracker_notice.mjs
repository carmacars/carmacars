import { hero, p, facts, notice, button, small } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_tracker_notice',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Tracker events are on (Admin > Cars > Fleet tracking > Tracking settings; migration 3320) and the Tracker of a car out on this renter\'s rental recorded an event that carries a charge or breaks the rental agreement: a speeding record over 180, 220 or 300 km/h, the car outside Ontario, still driving after the return time, the Tracker unplugged or tampered with, or the car parked at an impound lot. It says what happened, the charge and the clause. Once per event (one event per car, kind and window, 30 minutes by default). Always sent: the renter cannot mute it.',
  timing: 'Immediate, once per event',
  subject: '{{event_title}}: booking {{booking_number}}',
  preheader: '{{event_short}}',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Tracker notice', '{{event_title}}', '{{event_what}}'),
    p('Hi {{first_name}}, this is about your rental, booking {{booking_number}}.'),
    facts(
      ['When', '{{event_when}}'],
      ['The charge', '{{event_fee}}'],
      ['The clause', '{{event_clause}}'],
    ),
    notice('alert', 'What we ask', '{{event_ask}}'),
    button('Open my booking', '@booking'),
    p('Questions, or something we should know? Call **{{support_phone}}**, any time. We would rather sort it out with you than add charges.'),
    small('The Tracker records location, speed, distance, ignition and tampering, as section 12 of your rental agreement says. Its record is the evidence, and you can ask us for it.'),
  ],
  sample: {
    event_title: 'Speeding over 180 km/h',
    event_what: 'The Tracker in your 2024 Honda Civic Sport recorded 187 km/h on Sat, Nov 21, 2026 at 2:14 pm.',
    event_when: 'Sat, Nov 21, 2026 at 2:14 pm',
    event_fee: 'A speeding charge of $500.00 plus HST applies (over 180 km/h). It is taken from your Deposit first, and you get the Tracker\'s time, place and speed with it.',
    event_clause: 'Rental agreement: 10.5 Speeding charges.',
    event_ask: 'Please slow down. Driving faster than 180 km/h is never allowed, and each new record is a new charge.',
    event_short: '187 km/h recorded. A $500.00 charge applies (agreement 10.5). Please slow down.',
  },
};
