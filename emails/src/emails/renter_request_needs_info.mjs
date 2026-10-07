import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_request_needs_info',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Staff send a "more information needed" message on a booking with status requested. This is an event, not a status: the booking stays requested. Staff must enter the question (info_request) and a reply-by time (reply_by).',
  timing: 'Immediate',
  subject: 'One question before we can send your offer',
  preheader: 'Reply by {{reply_by}} so we can send your offer for the {{vehicle_name}}.',
  ref: 'Request {{booking_number}}',
  body: [
    hero('We need one thing', 'A quick question about your request', 'We cannot send your offer for the {{vehicle_name}} until we hear back, {{first_name}}.'),
    notice('alert', 'What we need from you', '{{info_request}}'),
    trip(),
    button('Answer now', '@booking_request'),
    p('Please answer by **{{reply_by}}**. After that we may close the request. Nothing is booked until you approve an offer, sign and pay. You can also reply to this email.'),
  ],
  sample: {
    info_request: 'You listed a second driver. Please tell us their full name and date of birth so we can price the booking correctly.',
    reply_by: 'Wed, Oct 21 at 12:00 pm',
  },
};
