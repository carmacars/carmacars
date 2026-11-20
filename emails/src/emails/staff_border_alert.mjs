import { hero, facts, notice, button, link, small } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_border_alert',
  audience: 'staff_va_fleet',
  also: ['staff_admin'],
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Tracker events are on (migration 3324) and a car\'s Tracker shows it has crossed out of Ontario (into another province or a state) or out of Canada. Once per crossing. Leaving Canada also raises an urgent Fleet To do. Always sent to Fleet and Admins, at once (not in the staff digest); the staff alert beside it is locked on.',
  timing: 'Immediate, once per crossing',
  subject: '{{border_title}}: {{car_label}}',
  preheader: '{{booking_line}}. {{border_when}}.',
  ref: '{{car_label}}',
  body: [
    hero('Border alert', '{{border_title}}', '{{car_label}} crossed on {{border_when}}. {{booking_line}}.'),
    facts(
      ['Car', '{{car_label}}'],
      ['When', '{{border_when}}'],
      ['Rental', '{{booking_line}}'],
      ['Clause', '{{border_clause}}'],
    ),
    notice('alert', 'Do now', '{{border_action}}'),
    button('Open Fleet tracking', '@va_fleet_tracking'),
    link('See the place on a map', '{{border_map_url}}'),
    small('The renter and the car\'s owner are told by themselves. The Tracker evidence record is kept with the event.'),
  ],
  sample: {
    border_title: 'Left Canada', car_label: '2024 Honda Civic Sport (CC-7F3A)', border_when: 'Sat, Nov 21, 2026 at 2:14 pm', booking_line: 'Booking CC-10482',
    border_clause: 'Rental agreement 10.1 Area; 12.3 Grounds', border_map_url: 'https://www.google.com/maps?q=42.88600,-78.87800',
    border_action: 'Call the renter now. Leaving Canada needs our written approval: if there is none and you cannot reach them, tell an Admin (ending the rental and recovery are section 12).',
  },
};
