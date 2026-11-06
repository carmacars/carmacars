import { hero, small, figure, facts, button, when, p } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'partner_invoice',
  audience: 'partner',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'An invoice to a partner (a body shop, tow truck or storage yard) for its kickback on a claim, towing or storage total is sent from the admin portal (Money > Partner invoices, Send), sent again, or reminded once before and once after its due date (migration 0547). The link opens the invoice PDF.',
  timing: 'When Finance or an Admin sends it; the reminders on their days',
  subject: '{{reminder_line}} Invoice {{invoice_number}} from CarmaCars: {{invoice_total}}',
  preheader: 'Claim {{claim_number}}. Due {{due_on}}.',
  ref: 'Invoice {{invoice_number}}',
  body: [
    hero('Invoice', 'Invoice {{invoice_number}}', 'Hello {{first_name}}. Here is our invoice to {{partner_name}} for the outsourced services below.'),
    when('is_reminder', [p('{{reminder_line}} The balance is {{invoice_balance}}.')]),
    figure('Total due', '{{invoice_total}}', 'Due {{due_on}}. Please quote the invoice number with your payment.'),
    facts(
      ['Invoice', '{{invoice_number}}'],
      ['Claim number', '{{claim_number}}'],
      ['Due', '{{due_on}}'],
      ['Cheque payable to', '{{payee}}'],
      ['e-Transfer to', '{{etransfer}}'],
    ),
    button('Open the invoice (PDF)', '{{pdf_url}}'),
    small('Questions about a line? Reply to this email.'),
  ],
  sample: {
    invoice_number: 'PI-000012', partner_name: 'Example Collision Centre', first_name: 'Sam', invoice_total: '$1,130.00', invoice_balance: '$1,130.00',
    due_on: 'Nov 20, 2026', claim_number: 'CL-2026-00001', payee: '18122211 Canada Inc.', etransfer: 'billing@carmacars.ca',
    pdf_url: 'https://carmacars.ca/api/partner-invoice/sample', is_reminder: false, reminder_line: '',
  },
};
