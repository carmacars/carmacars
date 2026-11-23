import { hero, small, facts, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_bank_line_unmatched',
  audience: 'staff_va_finance',
  also: ['staff_admin'],
  category: 'transactional',
  from: FROM.billing,
  digest: true,
  digestSlot: 'morning',
  trigger: 'Release 49 (3480): daily check and every bank import. A line on the bank statement still matches no payout, payment, invoice or expense two days (finance_bank_unmatched_days) after it posted. A To do for Finance is raised with it; matching the line or setting it aside closes it. Queued for the morning digest of Finance and the Admins, once per line.',
  timing: 'Morning digest, once per line, two days after it posted',
  subject: 'Bank line with no match: {{bank_direction}} {{bank_amount}} on {{bank_posted_on}}',
  preheader: '{{bank_description}}. {{bank_hint}}',
  ref: 'Bank reconciliation',
  body: [
    hero('No match', 'A bank line has no match', 'Money moved on the CarmaCars bank account that nothing on the platform accounts for yet.'),
    facts(
      ['Amount', '{{bank_direction}} {{bank_amount}}'],
      ['Posted', '{{bank_posted_on}}'],
      ['Description', '{{bank_description}}'],
      ['Account', '{{bank_account}}'],
    ),
    small('{{bank_hint}}'),
    button('Open the bank lines', '@va_finance_bank'),
    small('Match it to its payout, payment or expense, record what it is, or set it aside with the reason (a bank fee, a transfer between CarmaCars accounts).'),
  ],
  sample: {
    bank_direction: 'in', bank_amount: '$1,520.40', bank_posted_on: 'Tue, Nov 3, 2026', bank_description: 'STRIPE PAYOUT ST-X1',
    bank_account: 'RBC CAD ending 4567', bank_hint: 'Nothing recorded fits: record what it is, or set it aside with the reason.',
  },
};
