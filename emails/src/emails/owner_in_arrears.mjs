import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_in_arrears',
  audience: 'owner',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'Debit-retry job on the 18th: the retry of a failed owner invoice also fails and the invoice status becomes in_arrears (the vehicle\'s arrears flag is set).',
  timing: 'The day the bank reports the failed retry (18th or after)',
  subject: 'In arrears: {{arrears_amount}} owing on your {{vehicle_name}}',
  preheader: 'The retry failed. Pay by {{removal_date}} to keep the vehicle in the program.',
  ref: 'Invoice {{invoice_number}}',
  body: [
    hero('In arrears', 'The retry failed. Your vehicle is in arrears.', 'We tried the debit for your {{vehicle_name}} a second time, {{first_name}}, and your bank returned it again.'),
    figure('Owing', '{{arrears_amount}}', 'Invoice {{invoice_number}}: fees {{amount}} plus the {{late_fee}} late fee.'),
    h('What happens now'),
    steps(
      ['You can pay today', 'Paying now clears the arrears and stops everything below.'],
      ['Otherwise we deduct it on {{next_payout_date}}', 'The amount comes out of this car\'s revenue at the next payout.'],
      ['Any balance left becomes a debt payable on demand', 'We may deduct it from the revenue of your other vehicles.'],
      ['After {{removal_date}} we may remove the vehicle', 'That is 30 days after the failed retry. You would pay the fees to transfer the registration back.'],
    ),
    when('is_self_managed', [
      notice('alert', 'New bookings are paused', 'While this vehicle is in arrears, it is not enabled for new bookings.'),
    ]),
    button('Pay {{arrears_amount}} now', '@owner_invoice'),
    small('Getting your car back is never delayed because money is owed. If there is a problem we should know about, reply to this email or call us today.'),
  ],
  sample: {
    arrears_amount: '$586.75', amount: '$536.75', late_fee: '$50.00', invoice_number: 'INV-2026-11-0042',
    next_payout_date: 'December 10', removal_date: 'December 18, 2026', is_self_managed: false,
  },
};
