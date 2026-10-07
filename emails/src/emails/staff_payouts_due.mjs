import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_payouts_due',
  audience: 'staff_admin',
  also: ['staff_va_finance'],
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'Payouts job on the 10th at 08:00: approved owner payouts are due to be sent by bank transfer that day. Also on the 15th at 08:00 for investor returns due on the Payment Date. One email to both admins and finance. If the run is not approved yet, the email says so.',
  timing: '10th (owners) and 15th (investor returns), 08:00',
  subject: 'Payouts due today: {{payout_count}} transfers, {{payout_total}}',
  preheader: '{{payout_run_name}}. {{payout_run_status}}',
  ref: 'Payout run',
  body: [
    hero('Payouts due today', '{{payout_count}} transfers to send', '{{payout_run_name}}. Send each transfer from the business account and record its reference.'),
    keyfacts(
      { label: 'Transfers', value: '{{payout_count}}' },
      { label: 'Total', value: '{{payout_total}}' },
    ),
    when('run_approved', [
      table({ each: 'payout_rows', cols: [{ head: 'Payee', value: '{{name}}', strong: true }, { head: 'Amount', value: '{{amount}}', align: 'right', strong: true }] }),
    ], [
      notice('alert', 'The run is not approved yet', 'Nothing can be paid until an admin approves the statements.'),
    ]),
    button('Open the payout run', '@admin_payouts'),
    small('Marking a payout as paid sends the payee their notice. Check the amount and the account before you send.'),
  ],
  sample: {
    payout_count: '14', payout_total: '$21,480.60', payout_run_name: 'Owner payouts for November', payout_run_status: 'Approved and ready to send.',
    run_approved: true,
    payout_rows: [{ name: 'Daniel Rossi', amount: '$1,922.25' }, { name: 'Lena Park', amount: '$2,410.00' }, { name: '11 more in the run', amount: '$17,148.35' }],
  },
};
