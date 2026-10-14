import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_debit_notice',
  audience: 'owner',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'Owner debit notice job, on the notice day (the debit day less the notice days in Program settings, 10 by default): the owner has issued invoices that will be debited automatically on the debit day from their pre-authorized debit account. One email per owner, listing every invoice in the debit. Required notice under the pre-authorized debit agreement.',
  timing: 'The notice days before the debit day (the 5th for the 15th by default)',
  subject: 'Pre-authorized debit on {{debit_date}}: {{debit_total}}',
  preheader: '{{debit_count_text}} from your account ending {{bank_last4}}. Nothing to do if your account is up to date.',
  ref: 'Debit on {{debit_date}}',
  body: [
    hero('Upcoming debit', 'We will debit {{debit_total}} on {{debit_date}}', 'This is your notice of the fees below, {{first_name}}. If your bank account is up to date, there is nothing to do.'),
    table({
      each: 'debit_items',
      cols: [
        { head: 'Invoice', value: '{{invoice_number}}', strong: true },
        { head: 'Vehicle', value: '{{vehicle}}' },
        { head: 'Covers', value: '{{covers}}' },
        { head: 'Amount', value: '{{amount}}', align: 'right', strong: true },
      ],
    }),
    facts(
      ['Debit date', '{{debit_date}}'],
      ['From', 'Your account ending {{bank_last4}}'],
      ['Total', '{{debit_total}}'],
    ),
    notice('info', 'Prefer to pay another way?', 'Pay any of these invoices by card from its page before {{debit_date}} and we will not debit it.'),
    button('View my invoices', '@owner_billing'),
    small('A debit can take up to 5 business days to clear. If your bank returns it, a {{late_fee}} late fee applies and {{retry_text}}. To change the account, update it under Banking before {{debit_date}}. We send this notice {{notice_days}} days ahead, as your pre-authorized debit agreement sets out.'),
  ],
  sample: {
    debit_date: 'Sun, Nov 15, 2026', debit_total: '$1,073.50', debit_count_text: '2 invoices', bank_last4: '6621', late_fee: '$50.00',
    retry_text: 'we try again from the 18th', notice_days: '10',
    debit_items: [
      { invoice_number: 'INV-1042', vehicle: '2023 Toyota RAV4 XLE', covers: 'November 2026', amount: '$536.75' },
      { invoice_number: 'INV-1043', vehicle: '2022 Hyundai Elantra Preferred', covers: 'November 2026', amount: '$536.75' },
    ],
  },
};
