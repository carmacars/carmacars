import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_return_findings',
  audience: 'staff_va_finance',
  category: 'transactional',
  from: FROM.bookings,
  digest: true,
  digestSlot: 'next',
  trigger: 'Fleet completes the review of a return (the return condition report is reviewed and the findings are saved on the booking). Queued for the next finance digest. Sent immediately to the admins as well when damage is recorded. (Message template T7, internal.)',
  timing: 'Next digest, same day as the return',
  source: 'T7',
  subject: 'Return findings: booking {{booking_number}}, {{findings_headline}}',
  preheader: '{{vehicle_name}}. Statement due within 7 business days of check-in.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Return findings', 'Booking {{booking_number}} is ready to bill', 'Fleet has reviewed the return of the {{vehicle_name}}. Price the findings and issue the statement.'),
    facts(
      ['Km out and in', '{{odometer_out}} and {{odometer_in}}'],
      ['Allowance', '{{km_allowance}}, driven {{km_driven}}'],
      ['Fuel out and in', '{{fuel_out}} and {{fuel_in}}'],
      ['Cleaning', '{{cleaning_grade}}'],
      ['Damage', '{{damage_summary}}'],
      ['Minutes late', '{{minutes_late}}'],
      ['Keys', '{{keys_summary}}'],
      ['Deposit', '{{deposit_amount}} {{deposit_method}}, release due {{deposit_release_due}}'],
    ),
    button('Bill this booking', '@va_finance_booking'),
    small('Price each finding from the charge table, before HST. Email the itemized statement with the record for each line. Release the deposit balance within 7 business days of check-in, target 2. Any damage line goes to an admin.'),
  ],
  sample: {
    findings_headline: 'fuel short, no damage', odometer_out: '18,240 km', odometer_in: '18,702 km', km_driven: '462 km', fuel_out: 'Full', fuel_in: '3/4',
    cleaning_grade: 'Standard', damage_summary: 'None', minutes_late: '0', keys_summary: '2 of 2 returned', deposit_method: 'held',
    deposit_release_due: 'Wed, Nov 4, 2026',
  },
};
