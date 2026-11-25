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
  subject: 'Still time for your check-in visit',
  preheader: 'Pick a time for the {{vehicle_name}} when it suits you. Free, about 15 minutes.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Check-in visit', 'Whenever suits you', 'Hi {{first_name}}. A gentle reminder: your {{vehicle_name}} was due for its free check-in visit around {{checkin_due_date}}. Pick any time in the next days, at our office or by request.'),
    button('Pick a time', '@booking_checkin'),
    small('Nothing to pay and nothing changes on your rental. It helps us keep the car in top shape and spot maintenance early.'),
  ],
  sample: { checkin_due_date: 'Monday, December 14' },
};
