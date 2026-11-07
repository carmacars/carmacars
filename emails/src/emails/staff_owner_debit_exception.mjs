import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_owner_debit_exception',
  audience: 'staff_admin',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'An owner\'s automatic debit cannot go ahead: no bank debit set up at the notice or on the debit day, the owner cancelled the debit at their bank, the amount went up after the notice, the bank sent the payment back, or the invoice is held for another reason. Paused invoices are not reported. Immediate to the Admins; an Admin task opens for a missing debit agreement.',
  timing: 'Immediate',
  subject: 'Can\'t collect {{debit_total}} from {{owner_name}}: {{reason_plain}}',
  preheader: '{{fix_text}}',
  ref: 'Owner debits',
  // r29 C4 (migrations 0583, 0584): what happened, how much (each amount in one plain line), what to do, one button.
  body: [
    hero('Owner payment', 'Can\'t collect {{debit_total}} from {{owner_name}}', 'We were going to take {{debit_total}} from {{owner_name}}\'s bank on {{debit_date}} for {{debit_for}}, and we can\'t: {{reason_plain}}.'),
    // r29 C4: each amount in one plain line
    rows('debit_items', '{{line}}', '{{how}}. Invoice {{invoice_number}}.', '{{url}}'),
    notice('info', 'What to do', '{{fix_text}}'),
    button('{{fix_label}}', '{{fix_url}}'),
  ],
  sample: {
    owner_name: 'Daniel Rossi', reason_plain: 'no bank debit set up', debit_date: 'Sun, Nov 15, 2026', debit_total: '$536.75',
    debit_for: 'invoice INV-1042 (2023 Toyota RAV4 XLE)',
    debit_items: [{ invoice_number: 'INV-1042', amount: '$536.75', car: '2023 Toyota RAV4 XLE', fee: 'monthly fee', period: 'November 2026', how: 'prorated: 20 of 30 days, plus HST',
        line: '$536.75: 2023 Toyota RAV4 XLE, monthly fee, November 2026', url: 'https://carmacars.ca/admin/owners/00000000-0000-0000-0000-000000000000#inv-INV-1042' }],
    fix_text: 'Send the owner the link to set up their bank debit. Nothing is taken until they do.',
    fix_label: 'Send the sign-up link', fix_url: 'https://carmacars.ca/admin/owner-money?tab=debits&owner=00000000-0000-0000-0000-000000000000&fix=setup',
  },
};
