import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'investor_return_paid',
  audience: 'investor',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'An investor monthly return row changes to paid (an admin sent the transfer on the Payment Date, the 15th of the month after the Return Month, and recorded its reference). Not sent for a reinvested return.',
  timing: '15th of each month, when the transfer is sent',
  subject: 'Payment sent: {{return_amount}} for {{statement_month}}',
  preheader: 'By electronic transfer to your account ending {{bank_last4}}.',
  ref: 'Payment notice',
  body: [
    hero('Payment sent', 'Your {{statement_month}} Return has been paid', 'Hello {{first_name}}. We sent the payment below today under your Investment Agreement.'),
    facts(
      ['Amount', '{{return_amount}}'],
      ['Return Month', '{{statement_month}}'],
      ['Sent on', '{{payment_date}}'],
      ['To', 'Account ending {{bank_last4}}'],
      ['Transfer reference', '{{payout_reference}}'],
    ),
    button('View statement', '{{statement_url}}'),
    small('Bank transfers can take a few business days to show. To change the account we pay, send written notice at least 10 days before a Payment Date.'),
  ],
  sample: {
    statement_month: 'July 2027', return_amount: '$500.00', payment_date: 'Sun, Aug 15, 2027', bank_last4: '0457',
    payout_reference: 'CC-IR-0815-004', statement_url: 'https://carmacars.ca/files/sample-investor-statement',
  },
};
