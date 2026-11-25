import { hero, small, facts, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_checkin_booked',
  audience: 'staff_va_fleet',
  also: ['staff_admin'],
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Release 50 (4000): a renter on a long-term rental picked a time for the monthly check-in visit (at the office, or by request). Immediate, once per time picked, to Fleet and the Admins.',
  timing: 'Immediate',
  subject: 'Check-in visit booked: {{vehicle_name}}, {{checkin_time}}',
  preheader: '{{renter_name}}, booking {{booking_number}}: {{checkin_place}}.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Check-in visit', 'A visit is booked', '{{renter_name}} booked the monthly check-in visit of the {{vehicle_name}}.'),
    facts(
      ['When', '{{checkin_time}}'],
      ['Where', '{{checkin_place}}'],
      ['Renter note', '{{checkin_note}}'],
    ),
    button('Open check-in visits', '@va_fleet_checkins'),
    small('Do the visit from the queue: photos of the four sides and the odometer, damage, tires, fluids and warning lights, notes.'),
  ],
  sample: { checkin_time: 'Monday, December 14, 2:30 pm', checkin_place: 'At the office', checkin_note: 'None' },
};
