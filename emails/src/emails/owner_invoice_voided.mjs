import { hero, p, small, button, facts, notice, when } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_invoice_voided',
  audience: 'owner',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'An Admin voids an issued owner invoice with a reason (nothing was paid on it). Its scheduled debit is cancelled. When a corrected invoice replaces it, that invoice has its own email once it is issued.',
  timing: 'Immediate',
  subject: 'Invoice {{invoice_number}} is cancelled',
  preheader: '{{void_reason}}',
  ref: 'Invoice {{invoice_number}}',
  body: [
    hero('Invoice cancelled', 'You do not need to pay invoice {{invoice_number}}', 'Hi {{first_name}}, we cancelled this invoice for your {{vehicle_name}}.'),
    facts(['Invoice no.', '{{invoice_number}}'], ['Amount', '{{invoice_total}}'], ['Vehicle', '{{vehicle_name}}']),
    notice('info', 'Why', '{{void_reason}}'),
    p('Nothing will be debited for it.'),
    when('has_replacement', [p('It is replaced by invoice {{replacement_number}}, with the correct amount. We send it to you when it is ready.')]),
    button('View my invoices', '@owner_invoices'),
    small('Questions? Reply to this email.'),
  ],
  sample: {
    invoice_number: 'INV-1046', invoice_total: '$904.00', vehicle_name: '2023 Toyota RAV4 XLE',
    void_reason: 'The first and last month amount we agreed is $800.00, not $904.00.', has_replacement: true, replacement_number: 'INV-1053',
  },
};
