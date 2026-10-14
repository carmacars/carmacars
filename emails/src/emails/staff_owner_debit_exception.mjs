import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_owner_debit_exception',
  audience: 'staff_admin',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'An owner\'s automatic debit cannot go ahead: no active pre-authorized debit on file at the notice or on the debit day, the agreement was cancelled at the bank (Stripe mandate inactive), the balance grew after the notice, or the invoice is blocked for another reason. Paused invoices are not reported. Immediate to the Admins; an Admin task opens for a missing debit agreement.',
  timing: 'Immediate',
  subject: 'Owner debit exception: {{owner_name}}, {{exception_title}}',
  preheader: '{{debit_count_text}}, {{debit_total}}, due {{debit_date}}.',
  ref: 'Owner debits',
  body: [
    hero('Owner debit exception', '{{exception_title}}', '{{owner_name}}: {{exception_detail}}'),
    table({
      each: 'debit_items',
      cols: [
        { head: 'Invoice', value: '{{invoice_number}}', strong: true },
        { head: 'Vehicle', value: '{{vehicle}}' },
        { head: 'Amount', value: '{{amount}}', align: 'right', strong: true },
      ],
    }),
    facts(
      ['Owner', '{{owner_name}}'],
      ['Debit date', '{{debit_date}}'],
      ['Total', '{{debit_total}}'],
    ),
    button('Open owner debits', '@admin_debits'),
    small('From Owner debits you can pause the debit, send a new notice once the owner has set up banking, or record a payment received another way.'),
  ],
  sample: {
    owner_name: 'Daniel Rossi', exception_title: 'No pre-authorized debit on file',
    exception_detail: 'The owner has no active pre-authorized debit. They were emailed a link to set it up in Banking. Nothing is debited until they do; they can also pay from each invoice page.',
    debit_date: 'Sun, Nov 15, 2026', debit_total: '$536.75', debit_count_text: '1 invoice',
    debit_items: [{ invoice_number: 'INV-1042', vehicle: '2023 Toyota RAV4 XLE', amount: '$536.75' }],
  },
};
