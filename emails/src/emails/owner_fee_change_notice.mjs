import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_fee_change_notice',
  audience: 'owner',
  category: 'transactional',
  from: FROM.owners,
  digest: false,
  trigger: 'An admin changes a vehicle\'s terms after its Vehicle Schedule is signed: a higher Insurance Fee or Tracker Fee (a fee history row at least 30 days ahead), a higher Revenue Share (the same notice, and a new Vehicle Schedule opened for signature), or lower amounts (in force from today or a chosen date, no notice period). One email per change. is_share_change is true when a higher Revenue Share needs the owner\'s signature; is_decrease is true for lower amounts.',
  timing: 'Immediate: at least 30 days before the effective date of a higher amount; on the day a lower amount is set',
  subject: 'Notice of a change to your terms for the {{vehicle_name}}, from {{effective_date}}',
  preheader: '{{fee_change_summary}}',
  ref: 'Notice of change',
  body: [
    hero('Notice of change', 'Your terms for the {{vehicle_name}} are changing', 'This is your written notice, {{first_name}}. The change takes effect on {{effective_date}}.'),
    when('is_decrease', [figure('Effective', '{{effective_date}}', 'Lower amounts: no notice period is needed.')], [figure('Effective', '{{effective_date}}', '{{notice_days}} days from this notice.')]),
    compare('fee_changes', 'Now', 'From the effective date'),
    notice('info', 'Why', '{{fee_change_reason}}'),
    when('is_share_change', [
      p('A higher Revenue Share applies only if you sign the updated Vehicle Schedule, from the effective date or the day you sign, whichever is later. Until you do, your current share stays in place.'),
      button('Read and sign the new schedule', '@owner_agreements'),
    ], [
      p('You do not need to do anything. The new amounts appear on the first invoice dated on or after {{effective_date}}, charged on the {{debit_day}} as usual.'),
      button('View my vehicle', '@owner_vehicle'),
    ]),
    when('is_decrease', [
      small('This affects only the {{vehicle_name}}. The notice is also in your owner portal, under the vehicle\'s terms. Reply to this email with any questions.'),
    ], [
      small('This affects only the {{vehicle_name}}. If you would rather not continue on the new terms, you can give {{notice_period_days}} days\' written notice to take the vehicle out of the program. Reply to this email with any questions before the effective date.'),
    ]),
  ],
  allowButtons: true,
  sample: {
    effective_date: 'Fri, Jan 15, 2027', notice_days: '45', fee_change_summary: 'Insurance fee changes from $450.00 to $475.00 a month.',
    fee_changes: [{ label: 'Insurance fee, monthly, before HST', before: '$450.00', after: '$475.00' }],
    fee_change_reason: 'The premium for the fleet policy went up at renewal.', is_share_change: false, is_decrease: false,
  },
};
