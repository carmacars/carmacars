import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_late_return_alert',
  audience: 'staff_va_fleet',
  also: ['staff_admin'],
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Late-returns job (every 5 minutes): an on_rent booking passes its return time with no paid extension. Sent to Fleet at 0 minutes and at 30 minutes, and to Fleet and both admins at 2 hours. Immediate. The stage fills late_stage.',
  timing: 'At 0 and 30 minutes late (Fleet); at 2 hours (Fleet and admins)',
  subject: 'LATE {{minutes_late}} min: {{vehicle_name}}, booking {{booking_number}}',
  preheader: '{{renter_name}}, due {{return_time}}. {{late_action_short}}',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Late return', '{{vehicle_name}} is {{minutes_late}} minutes late', '{{renter_name}} was due back at {{return_time}}. Stage: {{late_stage}}.'),
    facts(
      ['Due', '{{return_date}}, {{return_time}}, {{return_place}}'],
      ['Renter', '{{renter_name}}, {{renter_phone}}'],
      ['Tracker', '{{tracker_summary}}'],
      ['Next booking on this car', '{{next_booking}}'],
    ),
    notice('alert', 'Do now', '{{late_action}}'),
    button('Open the booking', '@va_fleet_booking'),
    h('The ladder'),
    list(
      '**0 minutes:** call, check the tracker, offer a paid extension.',
      '**30 minutes:** charges start. Extra day plus the late fee from the return time.',
      '**2 hours:** call twice, send the final notice (1 hour to return or pay), tell an admin.',
      '**1 hour after the final notice:** only an admin approves disabling, and only with the car stationary and the ignition off.',
    ),
    small('Log every call, message and command in the incident log, with the time.'),
  ],
  sample: {
    minutes_late: '120', late_stage: '2 hours, final notice due', renter_phone: '416-555-0142',
    tracker_summary: 'Reporting. Moving east on Highway 401 at 2:02 pm', next_booking: 'Tue, Oct 27 at 9:00 am',
    late_action: 'Call twice. Send the final notice. Tell an admin now.', late_action_short: 'Call twice and send the final notice.',
    return_date: 'Mon, Oct 26, 2026', return_time: '12:00 pm',
  },
};
