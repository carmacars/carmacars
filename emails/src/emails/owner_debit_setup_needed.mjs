import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_debit_setup_needed',
  audience: 'owner',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'Owner debit notice job (or the debit run itself): the owner has invoices due for the automatic debit but no active pre-authorized debit agreement on file, or it was cancelled at the bank. Nothing is debited. One email per owner per debit date. An Admin gets the exception at the same time.',
  timing: 'The notice day, or the debit day when the agreement was cancelled since the notice',
  subject: 'Set up your bank debit for {{debit_total}} due {{debit_date}}',
  preheader: 'We have no pre-authorized debit for your account, so nothing was scheduled. It takes two minutes.',
  ref: 'Fees due {{debit_date}}',
  body: [
    hero('Action needed', 'Set up your pre-authorized debit', 'Your fees are paid by pre-authorized debit on the 15th, {{first_name}}, but we have no active bank account on file for you. Nothing was debited.'),
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
      ['Total due', '{{debit_total}}'],
      ['Due', '{{debit_date}}'],
    ),
    button('Set up my bank debit', '@owner_banking'),
    p('In Banking, choose **Set up pre-authorized debit**, enter your bank details in Stripe\'s secure form and accept the agreement. Later invoices are then debited on the debit day, with notice {{notice_days}} days before.'),
    small('You can also pay each invoice by card from its page. An invoice still unpaid after its due date takes a {{late_fee}} late fee, as your Enrollment Agreement sets out.'),
  ],
  sample: {
    debit_date: 'Sun, Nov 15, 2026', debit_total: '$536.75', notice_days: '10', late_fee: '$50.00',
    debit_items: [{ invoice_number: 'INV-1042', vehicle: '2023 Toyota RAV4 XLE', covers: 'November 2026', amount: '$536.75' }],
  },
};
