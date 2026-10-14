import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_fee_invoice',
  audience: 'owner',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'Owner-billing job on the 15th: a monthly owner invoice for a vehicle is issued and its pre-authorized debit is submitted. One invoice and one email per vehicle. Not sent for Turo-Only vehicles or vehicles owned personally by the two principals. (Message template T24.)',
  timing: '15th of each month',
  source: 'T24',
  subject: 'Invoice {{invoice_number}}: {{invoice_month}} fees for your {{vehicle_name}}, {{invoice_total}}',
  preheader: 'Due on the 15th. Pay from the invoice page by card or pre-authorized debit.',
  ref: 'Invoice {{invoice_number}}',
  body: [
    hero('Monthly fee invoice', '{{invoice_month}} fees for your {{vehicle_name}}', 'Your invoice for {{invoice_period}} is ready, {{first_name}}. It is due on the 15th.'),
    price({ each: 'invoice_lines', total: ['Total due on the 15th', '{{invoice_total}}'] }),
    facts(
      ['Invoice no.', '{{invoice_number}}'],
      ['Covers', '{{invoice_period}}'],
      ['Vehicle', '{{vehicle_name}}, plate {{vehicle_plate}}'],
      ['How to pay', '{{bank_last4}}'],
    ),
    button('View invoice', '@owner_invoice'),
    small('Fees run from the Enrollment Date to the Exit Date, whether or not the car is rented. A bank debit can take up to 5 business days to clear.'),
  ],
  sample: {
    invoice_number: 'INV-2026-11-0042', invoice_month: 'November', invoice_total: '$536.75', invoice_period: 'November 1 to 30, 2026', bank_last4: 'From the invoice page, with your saved method ending 6621',
    invoice_lines: [{ label: 'Insurance fee', amount: '$450.00' }, { label: 'Tracker fee', amount: '$25.00' }, { label: 'HST (13%)', amount: '$61.75' }],
  },
};
