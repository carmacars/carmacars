import { hero, small, table, figure, facts, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_pay_statement',
  audience: 'staff_field',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'An Admin records the payment of a field staff member\'s pay for a two-week pay period (Admin > Money > Field pay > Pay run > Record the payment; migration 0165), or sends the statement again. One email to that staff member, at their own address, with the figures of their pay statement (the PDF is in My hours).',
  timing: 'Immediate',
  subject: 'Your pay statement: {{period_label}}',
  preheader: '{{gross_total}}, {{payout_method}}, {{payout_date}}.',
  ref: 'Pay statement',
  body: [
    hero('Pay statement', 'Your pay for {{period_label}}', 'Hi {{first_name}}. Your pay for this period is recorded. The statement ({{statement_number}}) is in My hours.'),
    figure('Paid', '{{gross_total}}', '{{hours_total}} worked'),
    facts(
      ['How', '{{payout_method}}'],
      ['Date', '{{payout_date}}'],
      { label: 'Reference', value: '{{payout_reference}}', when: 'payout_reference' },
    ),
    table({
      each: 'pay_lines',
      cols: [
        { head: 'What', value: '{{what}}' },
        { head: 'Amount', value: '{{amount}}', align: 'right', strong: true },
      ],
    }),
    button('See my hours and statements', '{{hours_url}}'),
    small('No income tax, CPP or EI is taken off on this statement. If something looks wrong, reply to this email.'),
  ],
  sample: {
    period_label: 'Oct 18 to Oct 31, 2026', gross_total: '$612.00', hours_total: '32 h 00 min', payout_method: 'e-Transfer', payout_date: 'November 6, 2026',
    payout_reference: 'CA7xQ2', statement_number: 'PS-1001',
    pay_lines: [{ what: 'Hours: 32 h 00 min at $18.00', amount: '$576.00' }, { what: 'Commissions', amount: '$36.00' }],
    hours_url: 'https://carmacars.ca/field/hours',
  },
};
