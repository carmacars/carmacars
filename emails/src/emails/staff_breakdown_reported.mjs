import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_breakdown_reported',
  audience: 'staff_va_fleet',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'An incident row of type breakdown is created (a call to the 24-hour line is logged, or the renter reports it in the portal). Sent to the on-call Fleet person. Immediate.',
  timing: 'Immediate',
  subject: 'BREAKDOWN: {{vehicle_name}}, booking {{booking_number}}',
  preheader: '{{renter_name}} at {{breakdown_location}}. Dispatch roadside within 15 minutes.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Breakdown', 'Dispatch roadside within 15 minutes', '{{renter_name}} reported a breakdown in the {{vehicle_name}}.'),
    facts(
      ['Where', '{{breakdown_location}}'],
      ['Symptom', '{{breakdown_symptom}}'],
      ['Renter', '{{renter_name}}, {{renter_phone}}'],
      ['Tracker', '{{tracker_summary}}'],
    ),
    button('Open the booking', '@va_fleet_booking'),
    list(
      'Confirm the renter is safe first.',
      'Dispatch the roadside provider on file and send the renter the help notice.',
      'Mechanical and not the renter\'s fault: roadside is free, then a replacement car or a refund of unused time. Needs an admin.',
      'Lockout, fuel, flat battery from lights, tire damage or stuck: the renter pays the call-out cost plus the fee.',
      'Tell the owner and mark the car Out of Service.',
    ),
  ],
  sample: {
    breakdown_location: 'Highway 401 eastbound at Keele Street, right shoulder', breakdown_symptom: 'Engine warning light, loss of power',
    renter_phone: '416-555-0142', tracker_summary: 'Stationary since 1:14 pm, ignition on',
  },
};
