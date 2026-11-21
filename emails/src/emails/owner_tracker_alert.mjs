import { hero, p, facts, button, link, small } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_tracker_alert',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'Tracker events are on (Tracking settings; migration 3320) and the Tracker of one of this owner\'s cars recorded an event the owner asked to hear about in real time (3354, per the owner\'s request of Nov 20): the car stopped at an impound lot (the pound database), an auto shop or a shipping port (the watched places); possible theft (out of Ontario, out of Canada, far outside its zone with no booking, or moving with no active booking); the Tracker unplugged, offline or tampered with; a crash or impact; a vehicle health warning; driven over 180 km/h. Each is its own type in the owner\'s notification preferences: theft, tamper, crash and place on by default, health and speed off (the speed notice stays in the portal). Harsh driving, night driving and kilometres go in the weekly driving summary instead. Once per event (one per car, kind and window). The words name the car, the time and the place only: never the renter, the booking or any renter detail.',
  timing: 'Immediate, once per event',
  subject: '{{event_title}}',
  preheader: '{{event_short}}',
  ref: '{{vehicle_name}}',
  body: [
    hero('Tracker alert', '{{event_title}}', 'Hi {{first_name}}. {{event_what}}'),
    facts(
      ['Car', '{{vehicle_name}}'],
      ['When', '{{event_when}}'],
    ),
    button('See where your car is', '@owner_vehicle'),
    link('See the place on a map', '{{event_map_url}}'),
    p('CarmaCars has the same alert and is handling it. Any charge is collected from the driver with its evidence; we tell you because it is your car.'),
    small('You choose which tracker alerts you get, and how (email, text or the app), under Account, Notifications in your owner portal.'),
  ],
  sample: {
    first_name: 'Daniel',
    vehicle_name: '2023 Toyota RAV4 XLE',
    vehicle_id: '7315bf3e-0000-4000-8000-000000000001',
    event_title: 'Possible theft: your 2023 Toyota RAV4 XLE',
    event_what: 'It is moving with no active booking. CarmaCars has the same alert and is acting on it now. We will call you.',
    event_when: 'Fri, Nov 20, 2026 at 2:14 am',
    event_short: 'Your 2023 Toyota RAV4 XLE is moving with no active booking. CarmaCars is acting on it now.',
    event_map_url: 'https://www.google.com/maps?q=43.65320,-79.38320',
  },
};
