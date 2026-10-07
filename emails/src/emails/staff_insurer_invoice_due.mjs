import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_insurer_invoice_due',
  audience: 'staff_va_finance',
  also: ['staff_admin'],
  category: 'transactional',
  from: FROM.billing,
  digest: true,
  digestSlot: 'morning',
  trigger: 'Daily check at 06:00: an insurer_invoices row with status sent or part_paid has a balance and sent_at is 30 days ago. Queued once for the finance morning digest, then listed again every 7 days while the balance remains. At 60 days it is also queued for the admin digest.',
  timing: 'Morning digest, 30 days after the invoice was sent, then weekly',
  subject: 'Insurer invoice {{invoice_number}} unpaid for {{days_outstanding}} days: {{balance_due}}',
  preheader: '{{insurer_name}}, claim {{claim_number}}, booking {{booking_number}}. Chase the adjuster.',
  ref: 'Invoice {{invoice_number}}',
  body: [
    hero('Insurer invoice due', 'Unpaid for {{days_outstanding}} days', '{{insurer_name}} has not paid invoice {{invoice_number}} in full. Chase it today.'),
    figure('Balance', '{{balance_due}}', 'Invoiced {{invoice_total}}, received {{amount_paid}}.'),
    facts(
      ['Insurer', '{{insurer_name}}'],
      ['Claim no.', '{{claim_number}}'],
      ['Adjuster', '{{adjuster_contact}}'],
      ['Booking', '{{booking_number}}, {{renter_name}}'],
      ['Sent', '{{invoice_sent_at}}'],
      ['Last contact', '{{last_contact}}'],
    ),
    button('Open the invoice', '@va_finance_insurer_invoice'),
    list(
      'Email the adjuster with the invoice and the claim number. Log the date and the answer.',
      'Record any receipt against the invoice the day it arrives, with its reference.',
      'On a booking billed wholly to the insurer, the owner is paid for the rental only once the insurer pays.',
      'Only an admin can write an invoice off.',
    ),
  ],
  sample: {
    invoice_number: 'INS-0017', days_outstanding: '30', balance_due: '$1,582.00', invoice_total: '$1,582.00', amount_paid: '$0.00',
    insurer_name: 'Northern Mutual Insurance (sample)', claim_number: 'CL-88213-A', adjuster_contact: 'J. Tremblay, adjuster email and phone on the booking',
    invoice_sent_at: 'Mon, Oct 5, 2026', last_contact: 'None logged',
  },
};
