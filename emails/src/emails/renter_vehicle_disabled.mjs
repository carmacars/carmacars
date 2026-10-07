import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_vehicle_disabled',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'A tracker command of type engine disable for a booking is confirmed by the tracker (status confirmed), after admin approval. (Message template T15.)',
  timing: 'Immediate',
  source: 'T15',
  subject: 'Your rental has ended and the {{vehicle_name}} will not restart',
  preheader: 'If anyone is unsafe where it is parked, call {{roadside_phone}} now.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Rental ended', 'The car has been disabled', 'Your rental of the {{vehicle_name}} has ended, {{first_name}}. The car is parked and will not restart.'),
    notice('alert', 'If anyone is unsafe where the car is parked', 'Call **{{roadside_phone}}** now. We will re-enable the car so you can reach a safe place.'),
    p('Please call us to arrange the return of the car and all keys. Charges for the extra time and any recovery costs will appear on your statement, with the records for each line.'),
    link('View my booking', '@booking'),
  ],
  help: '**Call us:** {{support_phone}}, or the 24-hour line at {{roadside_phone}}.',
};
