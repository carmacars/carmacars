import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_payment_failed',
  audience: 'owner',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'The bank returns the automatic debit of an owner invoice for insufficient funds (the first debit): the invoice status becomes failed, the Late Fee is added once as its own line, and one retry of the original amount is scheduled on the later of the retry day and 3 business days after the return, within 30 days of the original debit. One email per vehicle. A debit returned for another reason sends owner_debit_returned instead. (Message template T25.)',
  timing: 'The day the bank reports the failed debit',
  source: 'T25',
  subject: 'Your {{amount}} payment for the {{vehicle_name}} failed',
  preheader: 'A {{late_fee}} late fee is added to your next debit. We retry {{amount}} on or after {{retry_date}}.',
  ref: 'Invoice {{invoice_number}}',
  body: [
    hero('Payment failed', 'Your fee payment did not go through', 'The debit for your {{vehicle_name}} was returned by your bank, {{first_name}}.'),
    price({
      rows: [['Invoice {{invoice_number}}, {{invoice_month}} fees', '{{amount}}'], ['Late fee', '{{late_fee}}']],
    }),
    p('We retry {{amount}} on or after {{retry_date}}. The {{late_fee}} late fee is collected with your next debit.'),
    notice('alert', 'Make sure the money is there on {{retry_date}}', 'We debit the same account again that day for {{retry_amount}}. If that fails too, this vehicle goes into arrears.'),
    button('Check my payment details', '@owner_billing'),
    small('If you changed banks, update your debit authorization before {{retry_date}}. This affects only the {{vehicle_name}}. Your other vehicles are billed separately. {{late_fee_rule}}'),
  ],
  sample: { amount: '$536.75', invoice_number: 'INV-2026-11-0042', invoice_month: 'November', late_fee: '$50.00', retry_date: 'Wed, Nov 18, 2026', retry_amount: '$536.75' },
};
