import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_return_details',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'The return field job of an on_rent booking has its place, time or assigned staff member changed after renter_return_reminder was sent, or is first assigned inside the last 24 hours before return.',
  timing: 'Immediate, only inside the 24 hours before return',
  subject: 'Return details for today: {{return_time}}, {{return_place}}',
  preheader: '{{field_staff_name}} will meet you. Bring all keys.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Return details', '{{field_staff_name}} will meet you at {{return_time}}', 'These are the confirmed details for handing back the {{vehicle_name}}, {{first_name}}.'),
    facts(
      ['When', '{{return_date}}, {{return_time}}'],
      ['Where', '{{return_place}}'],
      ['Who', '{{field_staff_name}} from CarmaCars'],
      { label: 'Meeting note', value: '{{meeting_note}}', when: 'meeting_note' },
    ),
    steps(
      ['Hand over the car and all keys', 'That moment is your check-in time.'],
      ['Walk around the car together', 'We record odometer, fuel, cleanliness and any new marks, with photos.'],
      ['Sign the condition report', 'You get a copy by email right after.'],
    ),
    button('Open return details', '@booking_return'),
    small('If you cannot make it on time, call {{support_phone}} before {{return_time}}.'),
  ],
  sample: { meeting_note: 'Same spot as pickup, taxi stand on the Front Street side.' },
};
