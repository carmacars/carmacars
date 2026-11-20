import { hero, p, facts, button, link, small } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_tracker_alert',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'Tracker events are on (migration 3320) and the Tracker of one of this owner\'s cars recorded an event: speeding, harsh driving, the car outside Ontario or the zone, driving after the return time or at night, the Tracker unplugged or tampered with, or the car parked at an impound lot. The event, the time and the place only: never the renter or the booking. Once per event (one per car, kind and window). The owner may mute it in their notification settings.',
  timing: 'Immediate, once per event',
  subject: '{{event_title}}: your {{vehicle_name}}',
  preheader: '{{event_short}}',
  ref: '{{vehicle_name}}',
  body: [
    hero('Tracker alert', '{{event_title}}', '{{event_what}}'),
    p('Hi {{first_name}}, this is about your car on CarmaCars.'),
    facts(
      ['Car', '{{vehicle_name}}'],
      ['When', '{{event_when}}'],
    ),
    button('Open my car', '@owner_vehicle'),
    link('See the place on a map', '{{event_map_url}}'),
    p('Nothing for you to do: CarmaCars handles it with the renter, and any charge is collected with its evidence. We tell you because it is your car.'),
    small('You can turn these alerts off, or choose email, text or the app, in your notification settings.'),
  ],
  sample: {
    event_title: 'Speeding over 180 km/h',
    event_what: 'Your 2023 Toyota RAV4 XLE was recorded at 187 km/h on Sat, Nov 21, 2026 at 2:14 pm. CarmaCars has told the renter and the speeding charge applies.',
    event_when: 'Sat, Nov 21, 2026 at 2:14 pm',
    event_short: 'Your 2023 Toyota RAV4 XLE was recorded at 187 km/h on Sat, Nov 21, 2026 at 2:14 pm.',
    event_map_url: 'https://www.google.com/maps?q=43.65320,-79.38320',
  },
};
