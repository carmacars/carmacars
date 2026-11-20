import { hero, p, small, price, button, notice, when, each, h } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'owner_use_charges',
  audience: 'owner',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'Owner-use charges (release 48, migration 3270), to an owner whose own booking of their car (for themselves or for someone else) had charges: damage up to the deductible, tickets, tolls, fuel, kilometres, cleaning, smoking, a late return or any other fee. Sent when the charges are billed (charged to the card on file, a bank debit started the same day, or due now with the pay link when there is no method on file or the charge failed), as a reminder every few days while unpaid, and when the unpaid invoice moves to the next statement after the due window (7 days by default). Each charge is listed with the evidence it rests on.',
  timing: 'Immediate, once per step',
  subject: '{{charge_title}}',
  preheader: '{{charge_how}}',
  ref: 'Invoice {{invoice_number}}',
  body: [
    hero('Your booking', '{{charge_title}}', 'Hi {{first_name}}. {{charge_text}}'),
    price({ each: 'charge_lines', total: ['Total', '{{invoice_total}}'] }),
    notice('info', 'How it is paid', '{{charge_how}}'),
    when('has_evidence', [h('The evidence for each charge'), each('charge_evidence', [p('**{{label}}.** {{note}}')])]),
    button('Open invoice {{invoice_number}}', '@owner_invoice'),
    small('The photos, readings and notices are on the invoice page and on your booking. If a charge looks wrong, reply to this email and we will check it with you.'),
  ],
  sample: {
    first_name: 'Karan', charge_title: '$186.45 is due now: charges on your booking B-10482',
    charge_text: 'These charges are from your own booking B-10482 of your 2021 Hyundai Sonata (Nov 14, 2026 to Nov 16, 2026). You are responsible for the charges of a booking you make for yourself or for someone else.',
    charge_how: 'We could not take it from a payment method on file. Please pay invoice INV-1088 now from the link. If it is not paid by Nov 27, 2026, it is deducted from your next statement.',
    charge_lines: [{ label: 'Refuelling: 22 litres', amount: '$73.45' }, { label: 'Smoking in the vehicle', amount: '$113.00' }],
    charge_evidence: [{ label: 'Refuelling: 22 litres', note: 'Evidence: the fuel or battery level at pickup and at return, the pickup and return photos' },
      { label: 'Smoking in the vehicle', note: 'Evidence: the guided evidence photos, a written description' }],
    has_evidence: true, invoice_number: 'INV-1088', invoice_total: '$186.45',
  },
};
