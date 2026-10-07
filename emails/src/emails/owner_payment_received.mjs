import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_payment_received',
  audience: 'owner',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'An owner invoice changes to paid: the debit for a monthly invoice clears (including a cleared retry), or the upfront invoice is paid by card or e-Transfer.',
  timing: 'Immediate',
  subject: 'Payment received: {{amount}} for invoice {{invoice_number}}',
  preheader: 'For your {{vehicle_name}}. Nothing more to do.',
  ref: 'Invoice {{invoice_number}}',
  body: [
    hero('Payment received', 'Paid. Thank you, {{first_name}}.', 'Your payment for the {{vehicle_name}} has cleared.'),
    figure('Received', '{{amount}}', 'Invoice {{invoice_number}}, {{payment_method}}.'),
    facts(
      ['Invoice no.', '{{invoice_number}}'],
      ['Received on', '{{payment_date}}'],
      ['Vehicle', '{{vehicle_name}}'],
    ),
    button('View invoice and receipt', '@owner_invoice'),
  ],
  sample: { amount: '$536.75', invoice_number: 'INV-2026-11-0042', payment_method: 'pre-authorized debit', payment_date: 'Wed, Nov 18, 2026' },
};
