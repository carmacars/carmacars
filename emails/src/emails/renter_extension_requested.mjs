import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_extension_requested',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'A booking extension row is created with status requested by the renter on an on_rent or confirmed booking.',
  timing: 'Immediate',
  subject: 'We have your extension request for booking {{booking_number}}',
  preheader: 'Your return time is unchanged until we confirm and you pay.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Extension requested', 'We are checking if the car is free', 'Thanks, {{first_name}}. We will reply as soon as we have checked the calendar.'),
    keyfacts(
      { label: 'Current return', value: '{{return_date}}', sub: '{{return_time}}' },
      { label: 'You asked for', value: '{{requested_return_date}}', sub: '{{requested_return_time}}' },
    ),
    notice('alert', 'Your return time has not changed', 'An extension counts only when we confirm it in writing and it is paid before {{return_time}} on {{return_date}}. Until then, please plan to return on time.'),
    button('View my booking', '@booking'),
    small('If your return time is close, call {{support_phone}} and we will deal with it on the phone.'),
  ],
  sample: { requested_return_date: 'Wed, Oct 28, 2026', requested_return_time: '10:00 am' },
};
