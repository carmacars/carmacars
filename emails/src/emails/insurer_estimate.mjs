import { hero, small, h, figure, facts, price, table, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'insurer_estimate',
  audience: 'insurer',
  category: 'transactional',
  // sent as Blind Spot Car Rental, replies to its mailbox, as the invoice (0187)
  from: FROM.blindspot,
  digest: false,
  trigger: 'An estimate for an insurance replacement is sent from Insurance replacements (Send as estimate, by email): what the rental will cost the insurer, with a 7-day link to the PDF of that version. It bills nothing. Sending again sends a new version.',
  timing: 'When Finance or an Admin sends the estimate',
  subject: 'Estimate {{invoice_number}} for {{renter_name}}: {{invoice_total}}',
  preheader: 'Rental of a {{vehicle_name}}, {{period}}. Claim {{claim_number}}. Not an invoice.',
  ref: 'Estimate {{invoice_number}}',
  body: [
    hero('Estimate', 'Estimate {{invoice_number}}', 'Hello {{first_name}}. Here is our estimate to {{insurer_name}} for the replacement rental below. It is not an invoice: nothing is due yet.'),
    figure('Estimated total', '{{invoice_total}}', 'Including HST. The invoice follows the end of the rental.'),
    facts(
      ['Estimate', '{{invoice_number}}, version {{version}}'],
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
      total: ['Estimated total', '{{invoice_total}}'],
    }),
    button('Download the estimate (PDF)', '{{invoice_url}}'),
    small('The download link works for {{link_expiry}}. To approve the estimate or ask about a line, reply to this email.'),
  ],
  sample: {
    insurer_name: 'Northbridge Mutual', first_name: 'Clara', invoice_number: 'INS-1004', version: '2', claim_number: 'CL-2026-77812', renter_name: 'Maya Chen',
    vehicle_name: '2023 Toyota RAV4 XLE', period: 'Fri, Oct 23, 2026 to Mon, Oct 26, 2026', invoice_amount: '$300.00', invoice_hst: '$39.00', invoice_total: '$339.00',
    invoice_lines: [{ label: 'Replacement rental, 3 days', amount: '$300.00' }], invoice_url: 'https://carmacars.ca/d/sample-estimate-link', link_expiry: '7 days',
  },
};
