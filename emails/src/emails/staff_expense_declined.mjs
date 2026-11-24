import { hero, small, facts, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_expense_declined',
  audience: 'staff_field',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'Release 50 (3720): Finance or an Admin declined an expense a field staff member added, with the reason. One email to that staff member, at their own address. Nothing is owed for it.',
  timing: 'Immediate',
  subject: 'Expense declined: {{expense_amount}}',
  preheader: '{{decided_by_name}}: {{decline_reason}}',
  ref: 'Expense {{expense_ref}}',
  body: [
    hero('Declined', 'Your expense was declined', 'Hi {{first_name}}. {{decided_by_name}} declined your expense of {{expense_amount}}: {{expense_description}}.'),
    facts(
      ['Reason', '{{decline_reason}}'],
      ['Amount', '{{expense_amount}}'],
      ['Whose money', '{{expense_paid_with}}'],
    ),
    button('See it on My shifts', '@field_shifts'),
    small('If you think this is wrong, reply to this email or ask Finance, with the receipt.'),
  ],
  sample: {
    expense_amount: '$64.20', expense_description: 'Gas for the Tesla Model 3', decided_by_name: 'Grace Lim', decline_reason: 'The receipt is for a personal car', expense_paid_with: 'Your own money', expense_ref: 'FS-3F2A9C',
  },
};
