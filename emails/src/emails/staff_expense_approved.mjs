import { hero, small, facts, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_expense_approved',
  audience: 'staff_field',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'Release 50 (3720): Finance or an Admin approved an expense a field staff member added. One email to that staff member, at their own address. Own money: it is now owed to them and shows on their pay as reimbursable until it is paid back.',
  timing: 'Immediate',
  subject: 'Expense approved: {{expense_amount}}',
  preheader: '{{expense_description}}. {{expense_reimburse_note}}',
  ref: 'Expense {{expense_ref}}',
  body: [
    hero('Approved', '{{expense_amount}} approved', 'Hi {{first_name}}. {{decided_by_name}} approved your expense: {{expense_description}}.'),
    facts(
      ['Amount', '{{expense_amount}}'],
      ['Whose money', '{{expense_paid_with}}'],
      ['Approved by', '{{decided_by_name}}'],
    ),
    button('See it on My shifts', '@field_shifts'),
    small('{{expense_reimburse_note}}'),
  ],
  sample: {
    expense_amount: '$64.20', expense_description: 'Gas for the Tesla Model 3', decided_by_name: 'Grace Lim', expense_paid_with: 'Your own money', expense_ref: 'FS-3F2A9C',
    expense_reimburse_note: 'It is added to what CarmaCars owes you, and paid back with your pay.',
  },
};
