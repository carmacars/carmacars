import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_incident_opened',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'An incident (accident, theft, vandalism, or damage found at return) is opened on a vehicle that belongs to a third-party owner, or a claim is opened for it. (Message template T17.)',
  timing: 'Immediate, the day the incident is opened',
  source: 'T17',
  subject: 'Incident involving your {{vehicle_name}} on {{incident_date}}',
  preheader: 'We are managing the claim and the repair. Please do not contact the insurer.',
  ref: 'Incident {{incident_number}}',
  body: [
    hero('Incident opened', 'Your {{vehicle_name}} was in an incident', 'We want you to hear this from us first, {{first_name}}. We are handling it.'),
    facts(
      ['What happened', '{{incident_summary}}'],
      ['When', '{{incident_date}}'],
      ['Where the car is now', '{{vehicle_location}}'],
      ['File no.', '{{incident_number}}'],
    ),
    h('What we do'),
    list(
      'We manage the claim and the repair at an approved shop.',
      'We keep the car off the calendar until the shop releases it.',
      'We update you when the estimate is in and when the car is back.',
    ),
    notice('alert', 'Please do not contact the insurer', 'All contact goes through CarmaCars so the claim is not delayed.'),
    button('Follow this incident', '@owner_claim'),
    small('Your monthly fees continue while the car is being repaired, and downtime is not paid.'),
  ],
  sample: {
    incident_number: 'INC-2041', incident_date: 'Sat, Oct 24, 2026', incident_summary: 'Low-speed collision in a parking lot. Damage to the rear bumper. No injuries.',
    vehicle_location: 'At our approved body shop',
  },
};
