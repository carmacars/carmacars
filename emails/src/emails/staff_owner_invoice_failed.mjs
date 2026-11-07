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
  subject: 'Owner payment bounced: {{amount}} from {{owner_name}}, {{vehicle_name}}',
  preheader: '{{fix_text}}',
  ref: 'Invoice {{invoice_number}}',
  // r29 C4 (migration 0583): what happened, how much, what to do, one button
  body: [
    hero('Owner payment', 'The bank sent back {{amount}}', 'We took {{amount}} from {{owner_name}}\'s bank for invoice {{invoice_number}} ({{vehicle_name}}), and the bank sent it back: {{bank_reason}}.'),
    // r29 C4: the amount in one plain line: the car, the fee, the period, how it was worked out, the invoice
    rows('amount_items', '{{line}}', '{{how}}. Invoice {{invoice_number}}.', '{{url}}'),
    notice('info', 'What to do', '{{fix_text}}'),
    button('Open the invoice', '@va_finance_invoice'),
  ],
  sample: {
    amount_items: [{ invoice_number: 'INV-2026-11-0042', amount: '$536.75', car: '2022 Hyundai Elantra Preferred', fee: 'monthly fee', period: 'November 2026', how: 'prorated: 20 of 30 days, plus HST',
        line: '$536.75: 2022 Hyundai Elantra Preferred, monthly fee, November 2026', url: 'https://carmacars.ca/admin/owners/00000000-0000-0000-0000-000000000000#inv-INV-2026-11-0042' }],
    owner_name: 'Daniel Rossi', invoice_number: 'INV-2026-11-0042', amount: '$536.75', bank_reason: 'Insufficient funds',
    fix_text: 'Nothing to do yet: we try again on Wed, Nov 18, 2026 for $586.75, late fee included. Record the payment on the invoice if they pay another way.',
    vehicle_name: '2022 Hyundai Elantra Preferred',
  },
};
