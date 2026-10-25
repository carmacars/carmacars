import { hero, p, small, compare, notice, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_fee_change_cancelled',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'An Admin cancels a change to a car\'s terms that had not started yet (migration 0165; History on the car page or the owner\'s terms): a higher or lower Insurance Fee, Tracker Fee or management fee noticed in writing, a Management Mode change, or an updated Vehicle Schedule that was waiting for the owner\'s signature. One email per cancelled change, saying what was going to change and that the terms stay as they are.',
  timing: 'Immediate',
  subject: 'The change to your terms for the {{vehicle_name}} is cancelled',
  preheader: 'Your terms stay as they are: {{fee_change_summary}}.',
  ref: 'Change cancelled',
  body: [
    hero('Change cancelled', 'We cancelled the change to your terms for the {{vehicle_name}}', 'Hi {{first_name}}. The change we told you about, planned for {{effective_date}}, will not happen.'),
    compare('fee_changes', 'Was going to be', 'Stays'),
    notice('info', 'What this means', 'Your terms for the {{vehicle_name}} stay as they are. You do not need to do anything, and there is nothing to sign.'),
    button('View my vehicle', '@owner_vehicle'),
    small('This affects only the {{vehicle_name}}. Reply to this email if you have a question.'),
  ],
  allowButtons: true,
  sample: {
    effective_date: 'Fri, Jan 15, 2027', fee_change_summary: 'Insurance Fee $450.00 to $475.00',
    fee_changes: [{ label: 'Insurance Fee, monthly, before HST', before: '$475.00', after: '$450.00' }],
  },
};
