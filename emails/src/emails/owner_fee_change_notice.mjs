import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_fee_change_notice',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'An admin schedules a change to a vehicle\'s Insurance Fee or Tracker Fee (a fee history row with a future effective date), or proposes a new Revenue Share (a new Vehicle Schedule opened for signature). One email per vehicle. A fee change must be sent at least 30 days before its effective date. is_share_change is true when the Revenue Share changes, which needs the owner\'s signature.',
  timing: 'Immediate, at least 30 days before the effective date',
  subject: 'Notice of a change to your terms for the {{vehicle_name}}, from {{effective_date}}',
  preheader: '{{fee_change_summary}}',
  ref: 'Notice of change',
  body: [
    hero('Notice of change', 'Your terms for the {{vehicle_name}} are changing', 'This is your written notice, {{first_name}}. The change takes effect on {{effective_date}}.'),
    figure('Effective', '{{effective_date}}', '{{notice_days}} days from this notice.'),
    compare('fee_changes', 'Now', 'From the effective date'),
    notice('info', 'Why', '{{fee_change_reason}}'),
    when('is_share_change', [
      p('A change to the Revenue Share applies only if you sign a new Vehicle Schedule. Until you do, your current share stays in place.'),
      button('Read and sign the new schedule', '@owner_agreements'),
    ], [
      p('You do not need to do anything. The new amounts appear on the first invoice dated on or after {{effective_date}}, charged on the 15th as usual.'),
      button('View my vehicle', '@owner_vehicle'),
    ]),
    small('This affects only the {{vehicle_name}}. If you would rather not continue on the new terms, you can give 30 days\' written notice to take the vehicle out of the program. Reply to this email with any questions before the effective date.'),
  ],
  allowButtons: true,
  sample: {
    effective_date: 'Fri, Jan 15, 2027', notice_days: '45', fee_change_summary: 'Insurance fee changes from $450.00 to $475.00 a month.',
    fee_changes: [{ label: 'Insurance fee, monthly, before HST', before: '$450.00', after: '$475.00' }],
    fee_change_reason: 'The premium for the fleet policy went up at renewal.', is_share_change: false,
  },
};
