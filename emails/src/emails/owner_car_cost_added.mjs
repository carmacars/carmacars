import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_car_cost_added',
  audience: 'owner',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'R50 hotfix 2 (5143): staff log an expense on the owner\'s car from its receipt, and the owner pays it: it is an owner deduction on the owner\'s next statement, with the receipt in the owner\'s documents.',
  timing: 'Immediate, when the expense is logged',
  subject: 'A cost for your {{vehicle_name}}: {{cost_amount}}',
  preheader: '{{cost_description}}. It comes off your next statement.',
  ref: 'Your {{vehicle_name}}',
  body: [
    hero('Car cost', 'A cost was added for your {{vehicle_name}}', 'Hi {{first_name}}, we paid this for your car. It comes off your next statement.'),
    facts(
      ['What', '{{cost_description}}'],
      ['Where', '{{cost_vendor}}'],
      ['Date on the receipt', '{{cost_date}}'],
      ['Amount with tax', '{{cost_amount}}'],
      ['Of which tax', '{{cost_tax}}'],
      ['Receipt photos', '{{receipt_count}}'],
    ),
    p('The receipt is in your owner portal under Documents, and the cost shows on your statement for the month.'),
    button('See your documents', '@owner_documents'),
    small('If this cost is not right, reply to this email before your statement is final and we will check it with the receipt.'),
  ],
  sample: {
    vehicle_name: '2021 Toyota RAV4', cost_description: 'Car service: oil change: Quick Lube', cost_vendor: 'Quick Lube', cost_date: 'Mon, Nov 23, 2026',
    cost_amount: '$96.05', cost_tax: '$11.05', receipt_count: '2',
  },
};
