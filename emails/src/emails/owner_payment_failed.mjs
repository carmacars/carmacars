import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_payment_failed',
  audience: 'owner',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'Debit-results job (15th to 25th, daily): the debit for a monthly owner invoice is returned and the invoice status becomes failed, which adds the Late Fee to that vehicle. One email per vehicle. (Message template T25.)',
  timing: 'The day the bank reports the failed debit',
  source: 'T25',
  subject: 'Your {{amount}} payment for the {{vehicle_name}} failed',
  preheader: 'A {{late_fee}} late fee applies. We retry on {{retry_date}}.',
  ref: 'Invoice {{invoice_number}}',
  body: [
    hero('Payment failed', 'Your fee payment did not go through', 'The debit for your {{vehicle_name}} was returned by your bank, {{first_name}}.'),
    price({
      rows: [['Invoice {{invoice_number}}, {{invoice_month}} fees', '{{amount}}'], ['Late fee', '{{late_fee}}']],
      total: ['We retry on {{retry_date}}', '{{retry_amount}}'],
    }),
    notice('alert', 'Make sure the money is there on {{retry_date}}', 'We debit the same account again that day for {{retry_amount}}. If that fails too, the amount is deducted from this car\'s revenue at the next payout.'),
    button('Check my payment details', '@owner_billing'),
    small('If you changed banks, update your debit authorization before {{retry_date}}. This affects only the {{vehicle_name}}. Your other vehicles are billed separately. {{late_fee_rule}}'),
  ],
  sample: { amount: '$536.75', invoice_number: 'INV-2026-11-0042', invoice_month: 'November', late_fee: '$50.00', retry_date: 'November 18', retry_amount: '$586.75' },
};
