import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_payment_reversed',
  audience: 'owner',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'An Admin voids a payment that was recorded by hand on an owner invoice (for example a cheque that was returned, or a payment recorded on the wrong invoice), with the reason. The invoice owes that amount again.',
  timing: 'Immediate',
  subject: 'Payment for invoice {{invoice_number}} was not received',
  preheader: '{{amount}} by {{payment_method}} on {{payment_date}}. {{balance}} is owing.',
  ref: 'Invoice {{invoice_number}}',
  body: [
    hero('Payment reversed', 'A payment did not go through', 'The {{amount}} we recorded for invoice {{invoice_number}} was reversed.'),
    notice('alert', 'Why', '{{void_reason}}'),
    facts(
      ['Invoice no.', '{{invoice_number}}'],
      ['Payment', '{{amount}} by {{payment_method}}'],
      ['Recorded for', '{{payment_date}}'],
      ['Vehicle', '{{vehicle_name}}'],
      ['Now owing', '{{balance}}'],
    ),
    p('No late fee applies. If this invoice has an automatic debit scheduled, it is debited on {{debit_date}} for {{balance}}; otherwise pay it from the invoice page.'),
    p('Please pay {{balance}} from the invoice page, or send it by e-Transfer with the invoice number in the message. Questions: reply to this email.'),
    button('View invoice', '@owner_invoice'),
  ],
  sample: {
    amount: '$350.00', invoice_number: 'INV-2026-11-0042', payment_method: 'cheque', payment_date: 'Tue, Nov 10, 2026',
    void_reason: 'The bank returned the cheque (insufficient funds).', balance: '$350.00', debit_date: 'Sun, Nov 15, 2026',
  },
};
