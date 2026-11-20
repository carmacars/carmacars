import { hero, facts, button, small } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_tracker_alert',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'Owner tracker alerts (release 48, migration 3264), in real time, to the owner of the car, only while trackers are available (Program settings: trackers_available) and only for the alert types the owner has on in their notification preferences: the car stopped at an impound lot, an auto shop or a shipping port on the watch list; possible theft (out of Ontario, far outside its zone with no booking, or moving with no active booking); the tracker disconnected or tampered with; a crash or impact; a vehicle health warning; driven over 180 km/h. Theft, tamper, crash and place alerts are on by default; health and speed are off. The words name the car only: never the renter, the booking or any renter detail.',
  timing: 'Immediate',
  subject: '{{alert_title}}',
  preheader: '{{alert_text}}',
  ref: '{{car_name}}',
  body: [
    hero('Tracker alert', '{{alert_title}}', 'Hi {{first_name}}. {{alert_text}}'),
    facts(['Car', '{{car_name}}'], ['When', '{{alert_time}}']),
    button('See where your car is', '@owner_vehicle'),
    small('You choose which tracker alerts you get, and how, under Account, Notifications in your owner portal.'),
  ],
  sample: {
    first_name: 'Daniel', car_name: '2023 Toyota RAV4 XLE', alert_title: 'Possible theft: your 2023 Toyota RAV4 XLE',
    alert_text: 'It is moving with no active booking. CarmaCars has the same alert and is acting on it now. We will call you.', alert_time: 'Fri, Nov 20 at 2:14 am',
    vehicle_id: '7315bf3e-0000-4000-8000-000000000001',
  },
};
