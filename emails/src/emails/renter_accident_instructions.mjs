import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_accident_instructions',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'An incident of type accident, theft or vandalism is opened on an on_rent booking (Fleet logs the renter\'s call). (Message template T16.)',
  timing: 'Immediate',
  source: 'T16',
  subject: 'What to do now, booking {{booking_number}}',
  preheader: 'If anyone is hurt call 911. Then follow these steps. Report due by {{report_due}}.',
  ref: 'Incident {{incident_number}}',
  body: [
    hero('Incident reported', 'Here is what to do now', 'We have opened a file for the {{vehicle_name}}, {{first_name}}. If anyone is hurt, call 911 first.'),
    steps(
      ['Make sure everyone is safe', 'Call 911 if anyone is hurt. Report to the police where the law requires it.'],
      ['Get the other party\'s details', 'Name, phone, licence, plate and insurer. Ask witnesses for a name and number.'],
      ['Take photos', 'All vehicles, the scene, the damage and any plates.'],
      ['Do not admit fault', 'Do not settle or sign anything at the scene.'],
      ['Send us your report', 'A written account, your photos and all keys, by **{{report_due}}**. That is 48 hours from the incident.'],
    ),
    button('Send my report and photos', '@booking_incident'),
    notice('info', 'If the car cannot be driven', 'We tow it to an approved shop and the rental ends. Call **{{roadside_phone}}** and we will arrange it.'),
    small('If you have coverage for this rental, tell your insurer or card issuer today.'),
  ],
  help: '**24-hour line:** {{roadside_phone}}. You can also reply to this email.',
  sample: { incident_number: 'INC-2041', report_due: 'Mon, Oct 26 at 3:30 pm' },
};
