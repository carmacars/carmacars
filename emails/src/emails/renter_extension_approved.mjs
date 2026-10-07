import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_extension_approved',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Booking extension status changes from requested to approved (staff checked the calendar, unpaid charges and coverage to the new return date). Payment is still outstanding.',
  timing: 'Immediate',
  subject: 'Extension available. Pay {{extension_amount}} by {{return_time}} to confirm',
  preheader: 'New return: {{new_return_date}}, {{new_return_time}}. Not confirmed until paid.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Extension available', 'You can keep the car. Pay to confirm.', 'The {{vehicle_name}} is free for the extra time, {{first_name}}. The extension is confirmed once you pay.'),
    keyfacts(
      { label: 'Current return', value: '{{return_date}}', sub: '{{return_time}}' },
      { label: 'New return', value: '{{new_return_date}}', sub: '{{new_return_time}}' },
    ),
    price({ each: 'extension_lines', total: ['To pay now', '{{extension_amount}}'] }),
    button('Pay and confirm the extension', '@booking_extend'),
    notice('alert', 'Pay before {{return_time}} on {{return_date}}', 'If it is not paid by then, the extension does not apply and the car is due back at the original time.'),
    small('We reprice the whole booking at its new length, so the extra can be less than the daily rate. New booking total: {{new_total_amount}}.'),
  ],
  sample: {
    new_return_date: 'Wed, Oct 28, 2026', new_return_time: '10:00 am',
    extension_lines: [{ label: 'Rental charge, 2 extra days', amount: '$200.00' }, { label: 'HST (13%)', amount: '$26.00' }],
    extension_amount: '$226.00', new_total_amount: '$694.95',
  },
};
