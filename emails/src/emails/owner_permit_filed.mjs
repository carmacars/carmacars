import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_permit_filed',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'R50 hotfix 2 (5144): an ownership permit (vehicle permit) is filed on the owner\'s car by staff, matched by its VIN, its plate or by hand.',
  timing: 'Immediate, when the permit is filed',
  subject: 'Ownership permit on file: {{vehicle_name}}',
  preheader: 'The permit for plate {{plate_text}} is in your documents.',
  ref: 'Your {{vehicle_name}}',
  body: [
    hero('Ownership permit', 'Your ownership permit is on file', 'Hi {{first_name}}, we filed the ownership permit of your {{vehicle_name}}.'),
    facts(
      ['Car', '{{vehicle_name}}'],
      ['Plate', '{{plate_text}}'],
    ),
    p('You can open it any time in your owner portal under Documents. Nothing else is needed from you for this document.'),
    button('See your documents', '@owner_documents'),
    small('If this is not your car\'s permit, reply to this email and we will fix it.'),
  ],
  sample: { vehicle_name: '2021 Toyota RAV4', plate_text: 'CCAB 123' },
};
