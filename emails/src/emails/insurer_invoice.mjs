import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'insurer_invoice',
  audience: 'insurer',
  category: 'transactional',
  // sent as Blind Spot Car Rental, replies to its mailbox (0187)
  from: FROM.blindspot,
  digest: false,
  trigger: 'An insurer invoice is sent from the admin portal (Send by email): the invoice for a replacement rental billed to an insurer, with a 7-day link to the PDF. Sending again sends a new email.',
  timing: 'When Finance or an Admin sends the invoice',
  subject: 'Invoice {{invoice_number}} for {{renter_name}}: {{invoice_total}}',
  preheader: 'Rental of a {{vehicle_name}}, {{period}}. Claim {{claim_number}}.',
  ref: 'Invoice {{invoice_number}}',
  body: [
    hero('Invoice', 'Invoice {{invoice_number}}', 'Hello {{first_name}}. Here is our invoice to {{insurer_name}} for the replacement rental below.'),
    figure('Total due', '{{invoice_total}}', 'Including HST. Please quote the invoice number with your payment.'),
    facts(
      ['Invoice', '{{invoice_number}}'],
      ['Claim number', '{{claim_number}}'],
      ['Renter', '{{renter_name}}'],
      ['Vehicle', '{{vehicle_name}}'],
      ['Rental period', '{{period}}'],
    ),
    h('Charges'),
    table({
      each: 'invoice_lines',
      cols: [
        { head: 'Item', value: '{{label}}' },
        { head: 'Amount', value: '{{amount}}', align: 'right' },
      ],
    }),
    price({
      rows: [
        ['Amount before HST', '{{invoice_amount}}'],
        ['HST', '{{invoice_hst}}'],
      ],
      total: ['Total due', '{{invoice_total}}'],
    }),
    button('Download the invoice (PDF)', '{{invoice_url}}'),
    small('The download link works for {{link_expiry}}. To pay by bank transfer or ask about a line, reply to this email.'),
  ],
  sample: {
    insurer_name: 'Northbridge Mutual', first_name: 'Clara', invoice_number: 'INS-1004', claim_number: 'CL-2026-77812', renter_name: 'Maya Chen',
    vehicle_name: '2023 Toyota RAV4 XLE', period: 'Fri, Oct 23, 2026 to Mon, Oct 26, 2026', invoice_amount: '$300.00', invoice_hst: '$39.00', invoice_total: '$339.00',
    invoice_lines: [{ label: 'Rental, 3 days at $100.00', amount: '$300.00' }], invoice_url: 'https://carmacars.ca/d/sample-invoice-link', link_expiry: '7 days',
  },
};
