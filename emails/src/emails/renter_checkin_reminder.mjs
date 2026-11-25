import { hero, small, facts, button, list } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_checkin_reminder',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Release 50 (4000): a long-term rental (longer than the check-in minimum, 28 days by default, a long-term weekly rental, or a booking with check-ins switched on) has its monthly check-in visit coming up: sent the reminder lead (5 days by default) before the visit is due, once per visit. A suggestion, never a requirement or a fee.',
  timing: 'Days before the visit is due (Program settings)',
  subject: 'Your monthly check-in visit: around {{checkin_due_date}}',
  preheader: 'A quick look at the {{vehicle_name}} to keep it in top shape. Nothing to pay. Pick a time that suits you.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Check-in visit', 'Time for a quick check-in', 'Hi {{first_name}}. Your {{vehicle_name}} is due for its monthly check-in visit around {{checkin_due_date}}. It takes about 15 minutes.'),
    list(
      'We look the car over and note its condition, so it stays in top shape for you',
      'We catch maintenance early (oil, tires, brakes), before it becomes a problem on the road',
      'There is nothing to pay: the visit is free and part of your rental',
    ),
    facts(
      ['Around', '{{checkin_due_date}}'],
      ['Where', '{{checkin_place}}'],
      ['Car', '{{vehicle_name}}'],
    ),
    button('Pick a time', '@booking_checkin'),
    small('It is a suggestion, not a requirement. If the dates do not suit you, pick another time or ask us to come to you.'),
  ],
  sample: { checkin_due_date: 'Monday, December 14', checkin_place: 'Our office, 123 Example Road, Toronto' },
};
