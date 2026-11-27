import { hero, small, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_checkin_followup',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Release 50 (4000): the monthly check-in visit of a long-term rental reached its due date and no time was picked. One gentle follow-up per visit, never more.',
  timing: 'On the due date, once',
  subject: 'Your free mid-rental car check: pick a time',
  preheader: 'You keep the {{vehicle_name}}: a free 15-minute look at it while you have it. Nothing to pay.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Mid-rental car check', 'Free, while you have the car', 'Hi {{first_name}}. The {{vehicle_name}} you are renting was due for its free mid-rental car check around {{checkin_due_date}}. It is not a pickup or a return: you keep the car. We look it over for about 15 minutes, at our office or where you ask. Pick any time in the next days.'),
    button('Pick a time', '@booking_checkin'),
    small('Nothing to pay and nothing changes on your rental. It helps us keep the car in top shape and catch maintenance early.'),
  ],
  sample: { checkin_due_date: 'Monday, December 14' },
};
