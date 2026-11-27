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
  subject: 'Your free mid-rental car check: around {{checkin_due_date}}',
  preheader: 'You keep the {{vehicle_name}}: a free 15-minute look at it to keep it in top shape. Pick a time that suits you.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Mid-rental car check', 'A free check while you have the car', 'Hi {{first_name}}. The {{vehicle_name}} you are renting is due for its free monthly car check around {{checkin_due_date}}. It is not a pickup or a return: you keep the car. It takes about 15 minutes.'),
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
