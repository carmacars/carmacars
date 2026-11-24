import { hero, small, facts, button, notice } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_expense_submitted',
  audience: 'staff_va_finance',
  also: ['staff_admin'],
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'Release 50 (3720): a field staff member adds money they spent for the company (gas, a wash, parts, parking, a service) with the receipt, and says whose money it was: their own (pay me back) or the company card or cash. Immediate, once per expense, to Finance and the Admins.',
  timing: 'Immediate',
  subject: 'Approve {{expense_amount}} spent by {{staff_name}}: {{expense_paid_with}}',
  preheader: '{{expense_description}}. {{expense_reimburse_note}}',
  ref: 'Expense {{expense_ref}}',
  body: [
    hero('Field expense', '{{expense_amount}} by {{staff_name}}', '{{staff_name}} added an expense: {{expense_description}}. Check the receipt, then approve or decline it with the reason.'),
    facts(
      ['Amount', '{{expense_amount}}'],
      ['Whose money', '{{expense_paid_with}}'],
      ['What', '{{expense_description}}'],
      ['Car', '{{expense_vehicle}}'],
      ['Receipt', '{{expense_receipt}}'],
    ),
    button('Open field spending', '@va_finance_field_spending'),
    notice('info', 'Pay back', '{{expense_reimburse_note}}'),
    small('Approved own-money expenses show on the payroll as reimbursable until you mark them paid back.'),
  ],
  sample: {
    expense_amount: '$64.20', staff_name: 'Marco Reyes', expense_paid_with: 'Their own money (pay them back)', expense_description: 'Gas for the Tesla Model 3',
    expense_vehicle: '2023 Tesla Model 3', expense_receipt: 'Attached', expense_ref: 'FS-3F2A9C',
    expense_reimburse_note: 'Approving it adds it to what CarmaCars owes Marco Reyes.',
  },
};
