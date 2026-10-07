import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_change_request_received',
  audience: 'staff_va_cs',
  category: 'transactional',
  from: FROM.bookings,
  digest: true,
  digestSlot: 'next',
  trigger: 'A booking change request row is created by a renter. Queued for the next customer service digest. Sent immediately instead when the pickup is less than 48 hours away or the booking is on_rent.',
  timing: 'Next digest. Immediate if pickup is within 48 hours or the car is on rent',
  subject: 'Change request on {{booking_number}}: {{change_summary}}',
  preheader: '{{renter_name}}, {{vehicle_name}}. Approve with a new price, or decline with a reason.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Change request', '{{renter_name}} asked to change a booking', 'The booking stays as it is until you approve and the renter accepts.'),
    compare('requested_changes', 'Now', 'Asked for'),
    facts(
      ['Booking status', '{{booking_status}}'],
      ['Vehicle', '{{vehicle_name}}'],
      { label: 'Renter note', value: '{{renter_note}}', when: 'renter_note' },
    ),
    button('Open the change request', '@va_cs_booking'),
    small('Check the calendar and reprice the whole booking at its new length. Escalate to an admin for a rate change, unpaid charges or a clash with another booking.'),
  ],
  sample: {
    change_summary: 'return one day later', booking_status: 'Confirmed', renter_note: '',
    requested_changes: [{ label: 'Return', before: 'Mon, Oct 26, 10:00 am', after: 'Tue, Oct 27, 10:00 am' }],
  },
};
