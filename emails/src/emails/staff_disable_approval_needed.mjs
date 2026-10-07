import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_disable_approval_needed',
  audience: 'staff_admin',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'A tracker command of type engine disable is created with status requested (Fleet asks after the final notice deadline passes, or on another ground in procedure 8). Sent to both admins. Immediate. The car is never disabled by a job.',
  timing: 'Immediate',
  subject: 'APPROVAL NEEDED: disable {{vehicle_name}}, booking {{booking_number}}',
  preheader: 'Requested by {{requested_by}}. Ground: {{disable_ground}}.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Admin decision', 'Fleet asks to disable the {{vehicle_name}}', 'Only an admin can approve this. Read the facts below before you decide.'),
    facts(
      ['Ground', '{{disable_ground}}'],
      ['Requested by', '{{requested_by}} at {{requested_at}}'],
      ['Final notice sent', '{{final_notice_at}}'],
      ['Renter', '{{renter_name}}, {{renter_phone}}'],
      ['Tracker now', '{{tracker_summary}}'],
    ),
    notice('alert', 'Before you approve', 'The car must be stationary with the ignition off. Never disable a moving car. If anyone is at risk where it is parked, re-enable at once.'),
    button('Review and decide', '@admin_approvals'),
    small('The system refuses the command unless a tracker reading from the last five minutes shows speed 0 and ignition off. Your decision and the reading are logged.'),
  ],
  sample: {
    disable_ground: 'Late return, 3 hours, no contact since the final notice', requested_by: 'Paolo (Fleet)', requested_at: '3:05 pm',
    final_notice_at: '2:05 pm', renter_phone: '416-555-0142', tracker_summary: 'Parked, ignition off since 2:48 pm, 14 Sample Road, Scarborough',
  },
};
