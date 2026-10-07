import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_request_needs_info',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Booking status changes from requested to needs_info. Staff must enter the question; it fills info_request.',
  timing: 'Immediate',
  subject: 'One question before we can send your offer',
  preheader: 'Reply by {{reply_by}} so we can hold the {{vehicle_name}} for you.',
  ref: 'Request {{booking_number}}',
  body: [
    hero('We need one thing', 'A quick question about your request', 'We cannot send your offer for the {{vehicle_name}} until we hear back, {{first_name}}.'),
    notice('alert', 'What we need from you', '{{info_request}}'),
    trip(),
    button('Answer now', '@booking_request'),
    p('Please answer by **{{reply_by}}**. After that we release the car to other renters and close the request. You can also reply to this email.'),
  ],
  sample: {
    info_request: 'You listed a second driver. Please tell us their full name and date of birth so we can price the booking correctly.',
    reply_by: 'Wed, Oct 21 at 12:00 pm',
  },
};
