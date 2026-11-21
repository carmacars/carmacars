import { hero, h, each, facts, button, small } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_tracker_weekly',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'Owner tracker alerts (release 48, migrations 3260 and 3353): Monday from 9:00 am Toronto time, once an owner a week, only for an owner who switched the weekly driving summary on in their notification preferences (off by default), only while Tracker events are on (Tracking settings), and only for a car with a tracker that was driven last week. Per car: kilometres driven, kilometres against the allowance of the rental days, speeding alerts, times over 180 km/h, hard braking, hard acceleration (the harsh driving marks of 3320) and late-night trips (the night hours of Tracker event settings, midnight to 5:00 am by default). No renter or booking is named.',
  timing: 'Weekly, Monday',
  subject: 'How your cars were driven: {{week_label}}',
  preheader: 'Speeding, hard braking, late-night driving and kilometres against the allowance.',
  ref: '{{week_label}}',
  body: [
    hero('Driving summary', 'How your cars were driven', 'Hi {{first_name}}, here is last week ({{week_label}}) from your trackers.'),
    each('cars', [
      h('{{car_name}}'),
      facts(['Kilometres driven', '{{km}}'], ['Allowance for the rental days', '{{allowance}}'], ['Against the allowance', '{{over}}'], ['Speeding alerts', '{{speeding}}'],
        ['Over {{speed_limit}} km/h', '{{over_limit}}'], ['Hard braking', '{{hard_braking}}'], ['Hard acceleration', '{{hard_acceleration}}'], ['Late-night trips', '{{late_night}}']),
    ]),
    button('Open your cars', '@owner_vehicles'),
    small('Kilometres over the allowance and speeding are charged to the renter under the rental agreement. Switch this summary off under Account, Notifications.'),
  ],
  sample: {
    first_name: 'Daniel', week_label: 'Mon, Nov 9, 2026 to Sun, Nov 15, 2026', speed_limit: '180',
    cars: [{ car_name: '2023 Toyota RAV4 XLE', km: '612 km', allowance: '800 km', over: 'Within the allowance', speeding: '2', over_limit: '0', hard_braking: '5', hard_acceleration: '3', late_night: '1' }],
  },
};
