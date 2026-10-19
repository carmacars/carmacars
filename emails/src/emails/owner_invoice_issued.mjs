import { hero, p, small, price, button, facts, notice, when } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_invoice_issued',
  audience: 'owner',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'An Admin issues an owner invoice made by hand (a registration fee or any other amount agreed with the owner, Admin > Money > Owner invoices, the owner page or the application), or a credit note, or presses Resend on one. Not sent for an invoice recorded as already paid (the receipt goes instead).',
  timing: 'Immediate',
  subject: '{{invoice_title}} {{invoice_number}} for the {{vehicle_name}}: {{invoice_total}}',
  preheader: 'Due {{due_date}}. Pay from the invoice page by card, debit or e-Transfer.',
  ref: 'Invoice {{invoice_number}}',
  body: [
    hero('Invoice', '{{invoice_title}}', 'Hi {{first_name}}, here is invoice {{invoice_number}} for your {{vehicle_name}}.'),
    price({ each: 'invoice_lines', total: ['Total', '{{invoice_total}}'] }),
    facts(['Invoice no.', '{{invoice_number}}'], ['Due', '{{due_date}}'], ['Vehicle', '{{vehicle_name}}']),
    when('has_notes', [notice('info', 'Note', '{{invoice_notes}}')]),
    when('is_credit', [p('This is a credit note: the amount is owed to you. We refund it or set it against your next invoice, as agreed with you.')],
      [p('You can pay by card, by pre-authorized debit or by e-Transfer. The invoice page has the details for each.')]),
    button('View the invoice', '@owner_invoice'),
    small('Questions about this invoice? Reply to this email.'),
  ],
  sample: {
    invoice_title: 'Registration fee', invoice_number: 'INV-1052', vehicle_name: '2023 Toyota RAV4 XLE', invoice_total: '$139.50', due_date: 'Mon, Oct 26, 2026',
    invoice_lines: [{ label: 'Registration fee', amount: '$123.45' }, { label: 'HST', amount: '$16.05' }],
    has_notes: true, invoice_notes: 'As agreed on the phone on October 19.', is_credit: false,
  },
};
