import { hero, p, small, button, facts, when, notice } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_stage_your_turn',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'Owner pipeline (r50, migration 4511): a car of the owner reached a stage of its onboarding that waits on the owner (finish the application, incorporate, sign, upload documents, the ServiceOntario transfer, the new ownership permit). Once per car and stage, from app.owner_stage_refresh (after any change, and the 15-minute sweep).',
  timing: 'When it becomes the owner\'s turn',
  subject: 'Your next step for the {{vehicle_name}}: {{stage_label}}',
  preheader: '{{action_text}}. Expected: {{expected}}.',
  ref: 'Owner onboarding',
  body: [
    hero('Step {{step_number}} of {{step_total}}', '{{stage_label}}', 'Hi {{first_name}}, your {{vehicle_name}} is ready for its next step, and it is yours:'),
    facts(
      ['To do', '{{action_text}}'],
      ['Bring', '{{bring_text}}'],
      ['Where', '{{where_text}}'],
      ['Expected time', '{{expected}}'],
    ),
    when('has_blockers', notice('warn', 'Before you start', '{{blockers_text}}')),
    button('Open my next step', '{{stage_url}}'),
    p('Your portal shows every step of your car\'s onboarding and who each one waits on.'),
    small('Questions? Reply to this email or call us.'),
  ],
  sample: { first_name: 'Pat', vehicle_name: '2021 Hyundai Sonata', stage_label: 'Ownership transfer', step_number: '6', step_total: '9',
    action_text: 'Book a ServiceOntario appointment', bring_text: 'Your driver\'s licence, the original ownership permit, proof of insurance and the filled Form A.',
    where_text: 'Any ServiceOntario centre that does vehicle registration.', expected: '30 to 60 minutes at the counter', has_blockers: true,
    blockers_text: 'Get a Safety Standards Certificate at a licensed inspection station (about 1 hour)', stage_url: 'https://carmacars.ca/owner/vehicles/v-1#stages' },
};
