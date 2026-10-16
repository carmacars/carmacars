import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_payout_sent',
  audience: 'owner',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'A payout row for an owner changes to paid (an admin sent the bank transfer and recorded its reference). Normally the 10th. Not sent when the statement shows a balance owing instead of a payout. (Message template T26, payment part.)',
  timing: '10th of each month, when the transfer is sent',
  source: 'T26',
  subject: 'Payout sent: {{payout_amount}} for {{statement_month}}',
  preheader: 'By bank transfer to your account ending {{bank_last4}}.',
  ref: 'Statement {{statement_number}}',
  body: [
    hero('Payout sent', 'Your {{statement_month}} payout is on its way', 'We sent your payout today by bank transfer, {{first_name}}.'),
    figure('Paid today', '{{payout_amount}}', 'To your account ending {{bank_last4}}.'),
    facts(
      ['Statement no.', '{{statement_number}}'],
      ['For', '{{statement_month}}'],
      ['Sent on', '{{payment_date}}'],
      ['Transfer reference', '{{payout_reference}}'],
    ),
    button('View the statement', '@owner_statement'),
    small('Bank transfers usually show within a few business days. If the account on file is no longer right, tell us before the next payout on the {{payout_day}}.'),
  ],
  sample: { payout_amount: '$1,922.25', statement_month: 'November', statement_number: 'ST-2026-11-0031', bank_last4: '6621', payment_date: 'Thu, Dec 10, 2026', payout_reference: 'CC-PO-1210-0031' },
};
