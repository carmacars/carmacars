import { hero, p, small, figure, compare, notice, button, when } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_mode_change_notice',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'An Admin changes the Management Mode of a car whose Vehicle Schedule is signed (migration 0165; the car page, Management Mode). When the change is against the owner (a higher fee or management fee, or a change CarmaCars starts) the owner signs an updated Vehicle Schedule and the date is at least the Notice Period ahead (needs_signature is true); when the owner asked for it and no amount is higher, the change is dated and applied by CarmaCars on that date. One email per change.',
  timing: 'Immediate: at least the Notice Period (30 days by default) before the date of a change against the owner; on the day it is made for a change the owner asked for',
  subject: 'Notice of a change to the Management Mode of your {{vehicle_name}}, from {{effective_date}}',
  preheader: '{{fee_change_summary}}',
  ref: 'Notice of change',
  body: [
    hero('Notice of change', 'The Management Mode of your {{vehicle_name}} is changing', 'This is your written notice, {{first_name}}. The change is for {{effective_date}}.'),
    figure('From', '{{effective_date}}', 'The {{vehicle_name}} changes from {{mode_before}} to {{mode_after}}.'),
    compare('fee_changes', 'Now', 'From the effective date'),
    notice('info', 'Why', '{{fee_change_reason}}'),
    when('needs_signature', [
      p('A change to your Vehicle Schedule is in writing, signed by both of us. It applies only once you sign the updated Vehicle Schedule, from the date above or the day you sign, whichever is later. Until you do, your current terms stay in place.'),
      button('Read and sign the new schedule', '@owner_agreements'),
      small('This affects only the {{vehicle_name}}. If you would rather not continue on the new terms, you can give {{notice_period_days}} days\' written notice to take the vehicle out of the program. Reply to this email with any questions.'),
    ], [
      p('You asked for this change and no amount is higher, so you do not need to sign anything. We issue the updated Vehicle Schedule on the date above and it appears in your owner portal.'),
      button('View my vehicle', '@owner_vehicle'),
      small('This affects only the {{vehicle_name}}. Reply to this email with any questions.'),
    ]),
  ],
  allowButtons: true,
  sample: {
    effective_date: 'Fri, Jan 15, 2027', mode_before: 'Self-Managed', mode_after: 'Managed',
    fee_change_summary: 'Management Mode Self-Managed to Managed, from Fri, Jan 15, 2027',
    fee_changes: [{ label: 'Management Mode', before: 'Self-Managed', after: 'Managed' }, { label: 'Management fee (Revenue Share)', before: '0%', after: '25%' }],
    fee_change_reason: 'You asked us to take over the rentals of this car.', needs_signature: true,
  },
};
