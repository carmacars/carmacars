import { hero, p, small, button, facts, when, notice } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_stage_nudge',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'Owner pipeline (r50, migration 4511): a salesperson, customer service, Fleet or an Admin pressed Nudge on the Owner pipeline or the owner\'s page. Reminds the owner of the one next step of their car. At most once in 10 minutes per car.',
  timing: 'When staff press Nudge',
  subject: 'Reminder: {{stage_label}} for your {{vehicle_name}}',
  preheader: '{{action_text}}. About {{expected}}.',
  ref: 'Owner onboarding',
  body: [
    hero('Reminder', 'One step and your car moves on', 'Hi {{first_name}}, {{agent}} from CarmaCars here. Your {{vehicle_name}} is waiting on this step:'),
    facts(
      ['Step', '{{stage_label}} ({{step_number}} of {{step_total}})'],
      ['To do', '{{action_text}}'],
      ['Bring', '{{bring_text}}'],
      ['Expected time', '{{expected}}'],
    ),
    when('has_blockers', notice('warn', 'Before you start', '{{blockers_text}}')),
    button('Open my next step', '{{stage_url}}'),
    small('Reply to this email if anything is in the way; we will help.'),
  ],
  sample: { first_name: 'Pat', agent: 'Darren', vehicle_name: '2021 Hyundai Sonata', stage_label: 'Documents uploaded', step_number: '5', step_total: '9',
    action_text: 'Upload: Driver\'s licence, Insurance slip', bring_text: 'Photos from your phone.', expected: 'About 5 minutes with your phone', has_blockers: false,
    blockers_text: '', stage_url: 'https://carmacars.ca/owner/vehicles/v-1#stages' },
};
