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
    hero('Owner debits', '{{submitted_count}} debits sent for {{submitted_total}}', 'The automatic owner debits of {{run_date}} have gone to the bank. Each one clears or comes back within about 5 business days.'),
    keyfacts(
      { label: 'Sent', value: '{{submitted_count}}' },
      { label: 'Not sent', value: '{{skipped_count}}' },
      { label: 'Refused', value: '{{failed_count}}' },
    ),
    // r29 C4: each debit in one plain line: the owner, the amount, the car, the fee, the period, how, the invoice
    rows('run_items', '{{owner}}, {{line}}', '{{status}}. {{how}}. Invoice {{invoice_number}}.', '{{url}}'),
    button('Open owner debits', '@admin_debits'),
    small('Owners with no bank debit set up ({{no_mandate_count}} today) were sent the link to set one up. A payment the bank sends back adds the late fee and is tried again as Program settings say.'),
  ],
  sample: {
    run_date: 'Sun, Nov 15, 2026', submitted_count: '12', submitted_total: '$6,441.00', skipped_count: '1', failed_count: '0', no_mandate_count: '1',
    run_items: [
      { owner: 'Daniel Rossi', status: 'Sent, waiting for the bank', invoice_number: 'INV-1042', amount: '$536.75', car: '2023 Toyota RAV4 XLE', fee: 'monthly fee', period: 'November 2026', how: 'prorated: 20 of 30 days, plus HST',
        line: '$536.75: 2023 Toyota RAV4 XLE, monthly fee, November 2026', url: 'https://carmacars.ca/admin/owners/00000000-0000-0000-0000-000000000000#inv-INV-1042' },
      { owner: 'Lena Park', status: 'Not sent: no bank debit set up', invoice_number: 'INV-1044', amount: '$536.75', car: '2022 Hyundai Elantra Preferred', fee: 'monthly fee', period: 'November 2026', how: 'full month, plus HST',
        line: '$536.75: 2022 Hyundai Elantra Preferred, monthly fee, November 2026', url: 'https://carmacars.ca/admin/owners/00000000-0000-0000-0000-000000000000#inv-INV-1044' },
    ],
  },
};
