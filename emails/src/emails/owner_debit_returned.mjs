import { hero, p, small, facts, button, notice, when } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_debit_returned',
  audience: 'owner',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'The bank returns the automatic debit of an owner invoice for a reason other than insufficient funds (for example the account is closed), or for insufficient funds too late for a retry within 30 days of the original debit. The debit is not retried: the automatic debit of that invoice is paused and an Admin is alerted at the same time. One email per returned debit.',
  timing: 'The day the bank reports the returned debit',
  subject: 'The debit for invoice {{invoice_number}} was returned',
  preheader: 'We will not debit this invoice again. Pay it from its page or update your bank account.',
  ref: 'Invoice {{invoice_number}}',
  body: [
    hero('Debit returned', 'Your bank returned the debit', 'The debit for your {{vehicle_name}} did not go through, {{first_name}}.'),
    notice('alert', 'What happened', 'The debit of {{debit_date}} was returned: {{bank_reason}}'),
    p('Pay this invoice from its page or update your bank account under Banking. We will not debit this invoice again.'),
    facts(
      ['Invoice no.', '{{invoice_number}}'],
      ['Vehicle', '{{vehicle_name}}'],
      ['Debit returned', '{{amount}}'],
      ['Now owing', '{{balance}}'],
    ),
    when('has_late_fee', [
      small('The {{late_fee}} Late Fee on this invoice is part of what is owing.'),
    ]),
    button('Pay this invoice', '@owner_invoice'),
  ],
  sample: {
    invoice_number: 'INV-2026-11-0042', debit_date: 'Sun, Nov 15, 2026', bank_reason: 'the account is closed', amount: '$536.75', balance: '$536.75',
    has_late_fee: false, late_fee: '$50.00',
  },
};
