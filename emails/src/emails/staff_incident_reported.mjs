import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_incident_reported',
  audience: 'staff_admin',
  also: ['staff_va_fleet'],
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'An incident row is created of type accident, theft, vandalism or damage (including damage recorded on a return condition report or found in the photo review). Sent to both admins and Fleet. Immediate.',
  timing: 'Immediate',
  subject: 'INCIDENT {{incident_number}}: {{incident_type}}, {{vehicle_name}}',
  preheader: 'Booking {{booking_number}}, {{renter_name}}. {{incident_summary}}',
  ref: 'Incident {{incident_number}}',
  body: [
    hero('Incident reported', '{{incident_type}}: {{vehicle_name}}', 'Opened by {{requested_by}} at {{requested_at}}. Every incident goes to an admin at once.'),
    facts(
      ['What happened', '{{incident_summary}}'],
      ['When and where', '{{incident_date}}, {{incident_place}}'],
      ['Booking', '{{booking_number}}, {{renter_name}}'],
      ['Injuries', '{{injuries}}'],
      ['Car drivable', '{{drivable}}'],
      ['Police report', '{{police_report}}'],
      ['Vehicle owner', '{{owner_name}}'],
    ),
    button('Open the incident', '@admin_incident'),
    h('Today'),
    list(
      'Not drivable: tow to an approved shop. The rental ends.',
      'Get the estimate from an approved shop only.',
      '$2,500 or more: tell the broker the same day.',
      'Send the owner their incident notice.',
      'Block the calendar until the shop releases the car.',
    ),
  ],
  sample: {
    incident_number: 'INC-2041', incident_type: 'Accident', incident_summary: 'Low-speed collision in a parking lot. Rear bumper damage.',
    incident_date: 'Sat, Oct 24, 2026 at 4:10 pm', incident_place: 'Yorkdale Shopping Centre parking, Toronto', injuries: 'None reported',
    drivable: 'Yes', police_report: 'Not required, renter says', requested_by: 'Paolo (Fleet)', requested_at: '4:32 pm',
  },
};
