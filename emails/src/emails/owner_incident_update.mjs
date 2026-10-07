import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_incident_update',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'A claim on a third-party owner\'s vehicle changes status (submitted, accepted, in_repair, repaired, settling, closed), or staff post an incident event marked visible to the owner.',
  timing: 'Immediate',
  subject: 'Update on incident {{incident_number}}: {{incident_status}}',
  preheader: 'Your {{vehicle_name}}. {{incident_update_short}}',
  ref: 'Incident {{incident_number}}',
  body: [
    hero('Incident update', '{{incident_status}}', 'Here is the latest on your {{vehicle_name}}, {{first_name}}.'),
    notice('info', 'Update of {{update_date}}', '{{incident_update}}'),
    facts(
      ['File no.', '{{incident_number}}'],
      ['Status', '{{incident_status}}'],
      { label: 'Expected back', value: '{{expected_back}}', when: 'expected_back' },
      { label: 'You need to', value: '{{owner_action}}', when: 'owner_action' },
    ),
    button('Follow this incident', '@owner_claim'),
    small('Please keep all contact about this claim with CarmaCars, not the insurer.'),
  ],
  sample: {
    incident_number: 'INC-2041', incident_status: 'In repair', update_date: 'Thu, Oct 29, 2026',
    incident_update: 'The shop has the parts and started work today. The repair is a rear bumper replacement and paint.',
    incident_update_short: 'The shop started the repair today.', expected_back: 'Wed, Nov 4, 2026', owner_action: '',
  },
};
