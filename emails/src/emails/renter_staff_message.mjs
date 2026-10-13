import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_staff_message',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'A customer service or sales assistant (or an Admin) replies to the renter in the messages of a booking. The message is kept on the booking and shown in the renter\'s account; this email carries it with a link to reply there. One email per message.',
  timing: 'Immediate',
  subject: 'A message about your booking {{booking_number}}',
  preheader: '{{staff_name}} at CarmaCars wrote about your {{vehicle_name}} booking.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Message', 'A message from our team', 'Hello {{first_name}}. {{staff_name}} wrote to you about booking {{booking_number}} for the {{vehicle_name}}.'),
    notice('info', '{{message_subject}}', '{{message_body}}'),
    button('Reply in your account', '@booking_messages'),
    small('Replies in your account reach the whole team and stay with the booking. You can also reply to this email.'),
  ],
  sample: {
    staff_name: 'Priya', message_subject: 'Your booking CC-10482',
    message_body: 'Thanks for asking about a child seat. We have added one to your booking at no extra charge for this trip. Let us know if you need anything else before pickup.',
  },
};
