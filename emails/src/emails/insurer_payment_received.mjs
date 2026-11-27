import { hero, small, figure, facts, when, p } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'insurer_payment_received',
  audience: 'insurer',
  category: 'transactional',
  // sent as Blind Spot Car Rental, replies to its mailbox (0187); never names the platform (5190)
  from: FROM.blindspot,
  digest: false,
  trigger: 'Finance or an Admin records a payment on an insurer invoice (app.record_insurer_payment, migration 5190): a receipt to the adjuster on the booking, or the insurer\'s billing contact, with the amount, what is left to pay, or that the invoice is paid in full. One email per payment.',
  timing: 'When the payment is recorded',
  subject: 'Payment received: invoice {{invoice_number}}, {{amount_paid}}',
  preheader: 'Claim {{claim_number}}. {{balance_line}}',
  ref: 'Invoice {{invoice_number}}',
  body: [
    hero('Payment received', 'Thank you, {{first_name}}', 'We received a payment from {{insurer_name}} on invoice {{invoice_number}}.'),
    figure('Paid', '{{amount_paid}}', 'Received {{paid_on}}.'),
    facts(
      ['Invoice', '{{invoice_number}}'],
      ['Claim number', '{{claim_number}}'],
      ['Renter', '{{renter_name}}'],
      ['Invoice total', '{{invoice_total}}'],
      ['Paid to date', '{{paid_to_date}}'],
      ['Balance', '{{balance}}'],
    ),
    when('paid_in_full', p('This invoice is now paid in full. There is nothing more to pay.'), p('The balance of {{balance}} is still due. Please quote the invoice number with your payment.')),
    small('Questions about this payment or the invoice: reply to this email.'),
  ],
  sample: {
    insurer_name: 'Northbridge Mutual', first_name: 'Clara', invoice_number: 'INS-1004', claim_number: 'CL-2026-77812', renter_name: 'Maya Chen',
    amount_paid: '$339.00', paid_on: 'Mon, Nov 30, 2026', invoice_total: '$339.00', paid_to_date: '$339.00', balance: '$0.00',
    balance_line: 'Paid in full.', paid_in_full: true,
  },
};
