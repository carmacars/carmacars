import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_statement_ready',
  audience: 'owner',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'An owner statement changes to issued: on the 10th of the month, after an admin approves the payout run, for the previous month. One statement and one email per owner, covering all their vehicles. (Message template T26, statement part.)',
  timing: '10th of each month',
  source: 'T26',
  subject: 'Your {{statement_month}} statement: {{payout_amount}}',
  preheader: 'Owner Revenue {{owner_revenue_total}}. {{payout_summary}}',
  ref: 'Statement {{statement_number}}',
  body: [
    hero('Monthly statement', 'Your {{statement_month}} statement is ready', 'Here are the totals across your vehicles, {{first_name}}. The full statement lists every rental.'),
    figure('{{payout_label}}', '{{payout_amount}}', '{{payout_summary}}'),
    h('By vehicle'),
    table({
      each: 'statement_vehicles',
      cols: [
        { head: 'Vehicle', value: '{{name}}', strong: true },
        { head: 'Owner Revenue', value: '{{owner_revenue}}', align: 'right' },
        { head: 'Payable', value: '{{payable}}', align: 'right', strong: true },
      ],
    }),
    h('Totals'),
    price({
      rows: [
        ['Rentals collected (rental charge and mileage overage)', '{{rentals_total}}'],
        ['Referral kickbacks deducted', '{{kickbacks_deducted}}'],
        ['Owner Revenue', '{{owner_revenue_total}}'],
        ['Revenue share kept by CarmaCars', '{{revenue_share_total}}'],
        ['Deductions (unpaid fees, late fees, owner costs)', '{{deductions_total}}'],
        ['Referral kickbacks you earned', '{{kickbacks_earned}}'],
        { label: 'HST on payout', value: '{{payout_hst}}', when: 'has_payout_hst' },
        { label: 'Balance brought forward', value: '{{balance_forward}}', when: 'has_balance_forward' },
      ],
      total: ['{{payout_label}}', '{{payout_amount}}'],
    }),
    button('View the full statement', '@owner_statement'),
    small('Deductions are limited to unpaid fees and late fees, costs we paid for you, your share of a refund or chargeback, and amounts you agreed to in writing. If a line looks wrong, reply to this email and tell us which one.'),
  ],
  sample: {
    statement_month: 'November', statement_number: 'ST-2026-11-0031', payout_label: 'Payout', payout_amount: '$1,922.25',
    payout_summary: 'Paid by bank transfer on December 10 to your account ending 6621.',
    statement_vehicles: [
      { name: '2023 Toyota RAV4 XLE', owner_revenue: '$1,760.00', payable: '$1,144.00' },
      { name: '2022 Hyundai Elantra Preferred', owner_revenue: '$2,100.00', payable: '$778.25' },
    ],
    rentals_total: '$4,060.00', kickbacks_deducted: '-$200.00', owner_revenue_total: '$3,860.00', revenue_share_total: '-$1,351.00',
    deductions_total: '-$586.75', kickbacks_earned: '$0.00', has_payout_hst: false, payout_hst: '$0.00', has_balance_forward: false, balance_forward: '$0.00',
  },
};
