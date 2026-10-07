import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_booking_request_new',
  audience: 'staff_va_cs',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'A booking row is created with status requested (booking event requested). Sent to every active customer service VA. Immediate, never batched.',
  timing: 'Immediate',
  subject: 'New request {{booking_number}}: {{vehicle_name}}, {{pickup_date}}',
  preheader: '{{renter_name}}, {{billable_days}} days, estimate {{estimate_amount}}. Review and send the offer.',
  ref: 'Request {{booking_number}}',
  body: [
    hero('New booking request', 'Review and send an offer', '{{renter_name}} asked for the {{vehicle_name}}. No card has been taken. The renter is waiting for our offer.'),
    keyfacts(
      { label: 'Pickup', value: '{{pickup_date}}', sub: '{{pickup_time}}' },
      { label: 'Return', value: '{{return_date}}', sub: '{{return_time}}' },
    ),
    facts(
      ['Renter', '{{renter_name}} ({{renter_history}})'],
      ['Drivers', '{{drivers_summary}}'],
      ['Pickup place', '{{pickup_place}}'],
      ['Estimate shown', '{{estimate_amount}}'],
      ['Identity documents', '{{identity_summary}}'],
      { label: 'Renter note', value: '{{renter_note}}', when: 'renter_note' },
    ),
    button('Open the request', '@va_cs_booking'),
    list(
      'Check the calendar, each driver\'s age and licence class, and the price.',
      'Adjust dates, car or price if needed, then send the offer. Or ask for information, or decline with a reason.',
      'Escalate to an admin for other discounts, travel outside Ontario, pets, a refusal, or more than 30 days.',
    ),
    small('Target: reply within 15 minutes during opening hours. At 2 hours without an answer, this request is flagged to the admins.'),
  ],
  sample: {
    estimate_amount: '$468.95', renter_history: 'new renter', drivers_summary: '1 driver, age 29, G licence',
    identity_summary: 'Licence and selfie uploaded, not reviewed', renter_note: 'Could pick up at 9:00 if that is easier.',
  },
};
