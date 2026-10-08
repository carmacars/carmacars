import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_monthly_statements_ready',
  audience: 'staff_admin',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'The company statement for a month is finalized (company statement status becomes final): the company statement and the owner statements for that month are drafted and need an admin\'s review before the owner statements are approved and issued. One email to each admin.',
  timing: 'Immediate, when the company statement is finalized',
  subject: '{{statement_month}} statements are drafted and need your review',
  preheader: 'Company statement final, {{owner_statement_count}} owner statements waiting. Payouts go out on {{payout_date}}.',
  ref: 'Month end',
  body: [
    hero('Review needed', '{{statement_month}} statements are drafted', 'The company statement is final and ties out, {{first_name}}. Review the owner statements and approve them before payouts on {{payout_date}}.'),
    keyfacts(
      { label: 'Owner statements', value: '{{owner_statement_count}}' },
      { label: 'Still in draft', value: '{{draft_count}}' },
    ),
    facts(
      ['Company statement', '{{company_statement_status}}'],
      ['Owner Revenue', '{{owner_revenue_total}}'],
      ['Revenue share kept', '{{revenue_share_total}}'],
      ['Total to pay owners', '{{payout_total}}'],
      ['Payout date', '{{payout_date}}'],
    ),
    button('Review the statements', '@admin_statements'),
    small('An owner sees a statement only once it is approved. A statement already issued can be reissued as a new version; the old one is kept.'),
  ],
  sample: {
    statement_month: 'November', owner_statement_count: '14', draft_count: '14', company_statement_status: 'Final, ties out',
    owner_revenue_total: '$34,910.00', revenue_share_total: '$11,204.50', payout_total: '$21,480.60', payout_date: 'Thu, Dec 10, 2026',
  },
};
