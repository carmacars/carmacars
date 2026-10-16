import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_statements_ready_for_approval',
  audience: 'staff_admin',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'Statements-draft job on the 5th at 06:00: the draft owner statements for last month are built and an approval task is raised. One email to both admins. A reminder is sent on the 8th at 09:00 if the run is still not approved.',
  timing: '5th of each month, reminder on the 8th',
  subject: '{{statement_month}} owner statements are ready for approval',
  preheader: '{{statement_count}} statements, {{payout_total}} to pay on the {{payout_day}}. Approve by the {{approve_by_day}}.',
  ref: 'Payout run',
  body: [
    hero('Approval needed', '{{statement_month}} statements are drafted', 'Review and approve the run by the {{approve_by_day}} so payouts go out on the {{payout_day}}.'),
    keyfacts(
      { label: 'Statements', value: '{{statement_count}}' },
      { label: 'Total to pay', value: '{{payout_total}}' },
    ),
    facts(
      ['Owner Revenue', '{{owner_revenue_total}}'],
      ['Revenue share kept', '{{revenue_share_total}}'],
      ['Deductions', '{{deductions_total}}'],
      ['Kickbacks to owners', '{{kickbacks_earned}}'],
      ['Field staff kickbacks, for payroll', '{{staff_kickbacks}}'],
      ['Owners with a balance owing', '{{negative_balances}}'],
      ['Flags', '{{statement_flags}}'],
    ),
    button('Review and approve', '@admin_statements'),
    small('Only these may be deducted: unpaid fees and late fees, owner costs we paid, the owner\'s share of a refund or chargeback, and amounts agreed in writing.'),
  ],
  sample: {
    statement_month: 'November', statement_count: '14', payout_total: '$21,480.60', owner_revenue_total: '$34,910.00', revenue_share_total: '$11,204.50',
    deductions_total: '$2,224.90', kickbacks_earned: '$400.00', staff_kickbacks: '$136.00', negative_balances: '1',
    statement_flags: '1 chargeback open, 2 vehicles with unpaid fees',
  },
};
