import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_renter_replied',
  audience: 'staff_va_cs',
  category: 'transactional',
  from: FROM.bookings,
  digest: true,
  digestSlot: 'next',
  trigger: 'A renter writes in the messages of their booking from their account. A "Renter replied" task opens in the customer service queue (one per booking while it is open). Queued for the next customer service digest; sent immediately instead when the car is out or the pickup is less than 48 hours away.',
  timing: 'Next digest. Immediate if the car is out or pickup is within 48 hours',
  subject: '{{renter_first_name}} replied about booking {{booking_number}}',
  preheader: '{{message_excerpt}}',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Renter message', '{{renter_first_name}} replied', 'A new message on booking {{booking_number}} ({{vehicle_name}}, {{booking_status}}, pickup {{pickup_date}}).'),
    notice('info', 'The message', '{{message_excerpt}}'),
    button('Open the booking', '@va_cs_booking'),
    small('Answer from the booking\'s messages so the reply reaches the renter by email and in their account. The task closes when you reply.'),
  ],
  sample: {
    renter_first_name: 'Maya', vehicle_name: '2023 Toyota RAV4 XLE', booking_status: 'confirmed', pickup_date: 'Fri, Oct 23, 2026',
    message_excerpt: 'Hi, can I pick up the car at 9:00 instead of 10:00? My flight lands earlier than planned.',
  },
};
