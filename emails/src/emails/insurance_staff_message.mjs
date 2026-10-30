import { hero, small, notice } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'insurance_staff_message',
  audience: 'renter',
  also: ['insurer'],
  category: 'transactional',
  from: FROM.blindspot,
  digest: false,
  trigger: 'A staff member writes from a booking billed to an insurer and sends it as Blind Spot Car Rental (insurance): Email the adjuster (to the adjuster\'s email on the booking), or Email the renter with Blind Spot Car Rental chosen as the sender (migration 0187). The subject is the one they typed. The message is kept on the booking with who sent it. One email per message.',
  timing: 'Immediate',
  subject: '{{message_subject}}',
  preheader: '{{staff_name}} at Blind Spot Car Rental wrote about {{about_line}}.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Message', 'A message from Blind Spot Car Rental', 'Hello {{first_name}}. {{staff_name}} wrote to you about {{about_line}}.'),
    notice('info', '{{message_subject}}', '{{message_body}}'),
    small('To answer, reply to this email. Replies reach the Blind Spot Car Rental insurance desk and stay with the booking.'),
  ],
  sample: {
    staff_name: 'Priya', message_subject: 'Replacement rental for claim CL-2026-77812',
    message_body: 'The renter picked up the 2023 Toyota RAV4 XLE today at 10:00 am. The authorization covers 10 days; please confirm whether it can be extended if the repairs take longer.',
    about_line: 'booking CC-10482, the 2023 Toyota RAV4 XLE, claim CL-2026-77812',
  },
};
