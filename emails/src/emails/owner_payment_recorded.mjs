import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_payment_recorded',
  audience: 'owner',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'An Admin or Finance records a payment received outside the card processor (e-Transfer, cheque, cash, bank transfer or another way) on an owner invoice, in full or in part. The receipt for that payment; the automatic debit stops, or debits only what is still owing.',
  timing: 'Immediate',
  subject: 'Receipt: {{amount}} received for invoice {{invoice_number}}',
  preheader: 'Paid by {{payment_method}} on {{payment_date}}. {{balance_line}}',
  ref: 'Invoice {{invoice_number}}',
  body: [
    hero('Payment received', 'Thank you, {{first_name}}.', 'We recorded your payment for the {{vehicle_name}}.'),
    figure('Received', '{{amount}}', 'Invoice {{invoice_number}}, paid by {{payment_method}}.'),
    facts(
      ['Invoice no.', '{{invoice_number}}'],
      ['Received on', '{{payment_date}}'],
      ['Paid by', '{{payment_method}}'],
      { label: 'Reference', value: '{{reference}}', when: 'has_reference' },
      ['Vehicle', '{{vehicle_name}}'],
      ['Still owing', '{{balance}}'],
    ),
    when('is_paid_in_full',
      p('This invoice is paid in full. Nothing will be debited for it.'),
      p('{{balance}} is still owing on this invoice. {{debit_line}}')),
    button('View invoice and receipt', '@owner_invoice'),
  ],
  sample: {
    amount: '$350.00', invoice_number: 'INV-2026-11-0042', payment_method: 'e-Transfer', payment_date: 'Tue, Nov 10, 2026',
    reference: 'CAxK7f2Pq', has_reference: true, balance: '$0.00', balance_line: 'Paid in full.', is_paid_in_full: true,
    debit_line: 'We debit only what is still owing, on the date of your notice.',
  },
};
