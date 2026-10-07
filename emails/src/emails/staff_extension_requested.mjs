import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_extension_requested',
  audience: 'staff_va_cs',
  also: ['staff_va_finance'],
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'A booking extension row is created with status requested. Immediate, because an extension must be confirmed in writing and paid before the current return time.',
  timing: 'Immediate',
  subject: 'Extension asked: {{booking_number}}, current return {{return_date}} {{return_time}}',
  preheader: '{{renter_name}} wants the {{vehicle_name}} until {{requested_return_date}}. Answer before the return time.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Extension request', 'Answer before {{return_time}} on {{return_date}}', '{{renter_name}} asked to keep the {{vehicle_name}} longer. It only counts if confirmed and paid before the current return time.'),
    keyfacts(
      { label: 'Current return', value: '{{return_date}}', sub: '{{return_time}}' },
      { label: 'Asked for', value: '{{requested_return_date}}', sub: '{{requested_return_time}}' },
    ),
    facts(
      ['Total length if approved', '{{new_length}}'],
      ['Unpaid charges', '{{unpaid_charges}}'],
      ['Coverage proof valid to', '{{coverage_valid_to}}'],
    ),
    button('Open the extension', '@va_cs_booking'),
    list(
      'Check the calendar, unpaid charges, and coverage proof to the new return date.',
      'Total of 30 days or less: reprice the whole booking and take the difference.',
      'Total over 30 days: it is a renewal, with a new booking and a new agreement.',
    ),
  ],
  sample: {
    requested_return_date: 'Wed, Oct 28, 2026', requested_return_time: '10:00 am', new_length: '5 days', unpaid_charges: 'None',
    coverage_valid_to: 'Dec 31, 2026',
  },
};
