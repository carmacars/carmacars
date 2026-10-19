import { hero, small, facts, button, notice } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_calendar_conflict',
  audience: 'staff_va_fleet',
  also: ['staff_admin'],
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'Calendar sync (every 10 minutes by default): a trip or block imported from another platform (Turo, Getaround or another calendar link) overlaps a confirmed or on-rent CarmaCars booking of the same car, turnaround included. One email per imported event and booking; it also raises an urgent Fleet task and shows on the Admin To do. Immediate.',
  timing: 'Immediate',
  subject: 'Double booking: {{vehicle_name}} on {{platform}} and {{booking_number}}',
  preheader: '{{platform}} has the car from {{external_start}} to {{external_end}}.',
  ref: 'Calendar sync',
  body: [
    hero('Calendar clash', 'The same car is booked twice', 'The {{platform}} calendar of the {{vehicle_name}} has a booking that overlaps CarmaCars booking {{booking_number}}. Decide which one keeps the car now.'),
    facts(
      ['Car', '{{vehicle_name}}'],
      ['{{platform}}', '{{external_start}} to {{external_end}}'],
      ['What it says', '{{external_summary}}'],
      ['CarmaCars booking', '{{booking_number}}: {{booking_start}} to {{booking_end}}'],
    ),
    button('Open calendar sync', '{{calendar_url}}'),
    notice('alert', 'What to do', 'Cancel or move one of the two trips, or swap the CarmaCars booking to another car. The task closes by itself once the dates no longer overlap.'),
    small('The turnaround between trips counts as part of each trip.'),
  ],
  sample: {
    vehicle_name: '2024 Mercedes-Benz C 300', platform: 'Turo', booking_number: 'CC-10482', external_start: 'Fri, Oct 23 at 10:00 am',
    external_end: 'Sun, Oct 25 at 10:00 am', external_summary: 'Turo trip', booking_start: 'Sat, Oct 24 at 9:00 am', booking_end: 'Mon, Oct 26 at 9:00 am',
    calendar_url: 'https://carmacars.ca/admin/calendar-sync',
  },
};
