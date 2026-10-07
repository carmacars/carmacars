import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_owner_invoice_failed',
  audience: 'staff_va_finance',
  also: ['staff_admin'],
  category: 'transactional',
  from: FROM.billing,
  digest: true,
  digestSlot: 'next',
  trigger: 'An owner invoice changes to failed (first debit returned) or in_arrears (retry on the 18th returned). Queued for the next finance digest. The in_arrears case is also sent immediately to both admins.',
  timing: 'Next digest. Immediate to admins when the retry fails',
  subject: 'Owner debit {{failure_stage}}: {{owner_name}}, {{vehicle_name}}, {{amount}}',
  preheader: 'Invoice {{invoice_number}}. {{failure_next_step}}',
  ref: 'Invoice {{invoice_number}}',
  body: [
    hero('Owner invoice failed', 'A fee debit was returned', '{{owner_name}}\'s debit for the {{vehicle_name}} did not clear. Stage: {{failure_stage}}.'),
    facts(
      ['Invoice', '{{invoice_number}}, {{invoice_month}}'],
      ['Amount', '{{amount}}'],
      ['Late fee', '{{late_fee}}'],
      ['Now owing', '{{arrears_amount}}'],
      ['Bank reason', '{{bank_reason}}'],
      ['Next step', '{{failure_next_step}}'],
    ),
    button('Open the invoice', '@va_finance_invoice'),
    list(
      '**First failure:** late fee added per vehicle, owner told, retry on the 18th.',
      '**Retry fails:** deduct from that vehicle\'s revenue at the next payout. Do not enable a Self-Managed car for new bookings. Tell an admin.',
      '**Balance left at the next 10th:** debt payable on demand. Deduct from the owner\'s other vehicles.',
      '**30 days after the failed retry:** an admin may remove the vehicle.',
    ),
  ],
  sample: {
    failure_stage: 'first failure', invoice_number: 'INV-2026-11-0042', invoice_month: 'November', amount: '$536.75', late_fee: '$50.00',
    arrears_amount: '$586.75', bank_reason: 'Insufficient funds', failure_next_step: 'Retry on November 18 for $586.75.',
    vehicle_name: '2022 Hyundai Elantra Preferred',
  },
};
