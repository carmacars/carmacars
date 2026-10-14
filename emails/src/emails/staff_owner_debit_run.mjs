import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_owner_debit_run',
  audience: 'staff_admin',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'The owner-debit run of a day is done (every scheduled debit due that day was sent, skipped or cancelled): one summary to the Admins with each debit and its status. Results that come back days later are in Owner debits; a returned debit also sends the owner invoice failure notice to finance.',
  timing: 'The debit day (the 15th by default), after the run',
  subject: 'Owner debits sent {{run_date}}: {{submitted_count}} for {{submitted_total}}',
  preheader: '{{skipped_count}} not sent, {{failed_count}} refused at once. Bank results follow over the next days.',
  ref: 'Owner debits',
  body: [
    hero('Owner debit run', '{{submitted_count}} debits sent for {{submitted_total}}', 'The automatic owner debits of {{run_date}} have gone to the bank. Each one clears or comes back within about 5 business days.'),
    keyfacts(
      { label: 'Sent', value: '{{submitted_count}}' },
      { label: 'Not sent', value: '{{skipped_count}}' },
      { label: 'Refused', value: '{{failed_count}}' },
    ),
    table({
      each: 'run_items',
      cols: [
        { head: 'Owner', value: '{{owner}}', strong: true },
        { head: 'Invoice', value: '{{invoice_number}}' },
        { head: 'Amount', value: '{{amount}}', align: 'right' },
        { head: 'Status', value: '{{status}}' },
      ],
    }),
    button('Open owner debits', '@admin_debits'),
    small('Owners without a debit agreement ({{no_mandate_count}} today) were asked to set one up. A returned debit adds the late fee and is tried again as Program settings say.'),
  ],
  sample: {
    run_date: 'Sun, Nov 15, 2026', submitted_count: '12', submitted_total: '$6,441.00', skipped_count: '1', failed_count: '0', no_mandate_count: '1',
    run_items: [
      { owner: 'Daniel Rossi', invoice_number: 'INV-1042', amount: '$536.75', status: 'Sent, processing' },
      { owner: 'Lena Park', invoice_number: 'INV-1044', amount: '$536.75', status: 'Not sent: no pre-authorized debit mandate' },
    ],
  },
};
