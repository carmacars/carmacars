import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_upfront_invoice',
  audience: 'owner',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'The upfront owner invoice for a vehicle is issued after documents_signed: the Install Fee plus the first and last month\'s Insurance Fee, with HST. Not issued for Turo-Only or shareholder-owned vehicles.',
  timing: 'Immediate',
  subject: 'Upfront invoice {{invoice_number}} for the {{vehicle_name}}: {{invoice_total}}',
  preheader: 'Pay by card or e-Transfer to start registration. No security deposit.',
  ref: 'Invoice {{invoice_number}}',
  body: [
    hero('Upfront invoice', 'One payment to get started', 'This is the only amount CarmaCars bills before your {{vehicle_name}} is enrolled, {{first_name}}.'),
    price({ each: 'invoice_lines', total: ['Total due', '{{invoice_total}}'] }),
    button('Pay this invoice', '@owner_invoice'),
    list(
      'Pay by card or by e-Transfer. The invoice page has the details for both.',
      'The first month\'s insurance fee pays your enrollment month. Any unused part is credited to your next charge.',
      'The last month\'s insurance fee is held and pays your exit month. Any unused part is refunded.',
      'There is no security deposit.',
    ),
    notice('info', 'Registry costs are separate', 'You pay ServiceOntario, the safety inspection and any appraisal directly. CarmaCars does not bill them.'),
  ],
  sample: {
    vehicle_name: '2023 Toyota RAV4 XLE', invoice_number: 'INV-U-0031', invoice_total: '$1,130.00',
    invoice_lines: [
      { label: 'Tracker install fee', amount: '$100.00' },
      { label: 'Insurance fee, first month', amount: '$450.00' },
      { label: 'Insurance fee, last month (held)', amount: '$450.00' },
      { label: 'HST (13%)', amount: '$130.00' },
    ],
  },
};
