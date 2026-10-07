import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_extension_confirmed',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Booking extension status changes to confirmed (the extension payment succeeded before the return time and the booking return time was moved). This is the written confirmation. (Message template T11.)',
  timing: 'Immediate',
  source: 'T11',
  subject: 'Extension confirmed. New return {{new_return_date}}, {{new_return_time}}',
  preheader: 'Booking {{booking_number}} repriced to {{new_total_amount}}. Paid today {{extension_amount}}.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Extension confirmed', 'Your new return is {{new_return_date}}', 'Paid and confirmed, {{first_name}}. This email is your written confirmation.'),
    keyfacts(
      { label: 'New return', value: '{{new_return_date}}', sub: '{{new_return_time}}' },
      { label: 'Where', value: '{{return_place}}' },
    ),
    facts(
      ['Booking total, repriced', '{{new_total_amount}}'],
      ['Paid today', '{{extension_amount}}'],
      ['Kilometres included', '{{km_allowance}} for the whole rental'],
      { label: 'Deposit', value: '{{deposit_note}}', when: 'deposit_note' },
    ),
    button('View my booking', '@booking'),
    small('All other terms of your rental agreement are unchanged.'),
  ],
  sample: {
    new_return_date: 'Wed, Oct 28, 2026', new_return_time: '10:00 am', extension_amount: '$226.00', new_total_amount: '$694.95',
    km_allowance: '1,000 km', deposit_note: '',
  },
};
