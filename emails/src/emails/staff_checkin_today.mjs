import { hero, small, facts, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_checkin_today',
  audience: 'staff_va_fleet',
  also: ['staff_admin'],
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Release 50 (4000): a monthly check-in visit is booked for today, or is due today without a time. Once per visit per day, from 7 am Toronto time, to Fleet and the Admins.',
  timing: 'The morning of the day',
  subject: 'Check-in visit today: {{vehicle_name}}',
  preheader: '{{renter_name}}, booking {{booking_number}}: {{checkin_time}}.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Check-in visit', 'On today', 'The monthly check-in visit of the {{vehicle_name}} ({{renter_name}}) is today.'),
    facts(
      ['When', '{{checkin_time}}'],
      ['Where', '{{checkin_place}}'],
    ),
    button('Open check-in visits', '@va_fleet_checkins'),
    small('Not booked yet? It is a suggestion to the renter: a friendly call is fine, never a charge.'),
  ],
  sample: { checkin_time: 'Due today, no time picked yet', checkin_place: 'At the office' },
};
