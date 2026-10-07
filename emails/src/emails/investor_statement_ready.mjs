import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'investor_statement_ready',
  audience: 'investor',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'An investor monthly statement for a Return Month is issued by an admin (after the returns accrual on the 1st). Sent only to existing investors with an active investment. Neutral servicing notice.',
  timing: 'Monthly, when the statement is issued',
  subject: 'Your {{statement_month}} statement is ready',
  preheader: 'Statement for {{statement_month}} under your Investment Agreement.',
  ref: 'Statement {{statement_number}}',
  body: [
    hero('Monthly statement', 'Your {{statement_month}} statement', 'Hello {{first_name}}. Your statement for {{statement_month}} under your Investment Agreement is ready.'),
    facts(
      ['Statement no.', '{{statement_number}}'],
      ['Return Month', '{{statement_month}}'],
      ['Return for the month', '{{return_amount}}'],
      ['Treatment', '{{return_treatment}}'],
      ['Invested Amount at month end', '{{invested_amount}}'],
    ),
    button('View statement', '{{statement_url}}'),
    small('The statement link works for 7 days. This notice reports on your existing investment under the terms of your signed agreement. It is not tax advice.'),
  ],
  sample: {
    statement_month: 'July 2027', statement_number: 'IS-2027-07-004', return_amount: '$500.00', return_treatment: 'To be paid on August 15, 2027',
    invested_amount: '$20,000.00', statement_url: 'https://carmacars.ca/files/sample-investor-statement',
  },
};
