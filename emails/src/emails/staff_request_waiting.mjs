import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_request_waiting',
  audience: 'staff_va_cs',
  also: ['staff_admin'],
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Scheduled check every 5 minutes: a booking has had status requested for more than 2 hours with no offer, information request or decline. Sent once per request, to customer service and both admins. Immediate.',
  timing: '2 hours after an unanswered request',
  subject: 'Waiting {{waiting_time}}: request {{booking_number}} has no offer',
  preheader: '{{renter_name}}, {{vehicle_name}}, pickup {{pickup_date}}. Answer it now.',
  ref: 'Request {{booking_number}}',
  body: [
    hero('Request waiting', 'This request has waited {{waiting_time}}', '{{renter_name}} has had no answer on the {{vehicle_name}}. Send an offer, ask a question or decline.'),
    facts(
      ['Received', '{{request_received_at}}'],
      ['Pickup', '{{pickup_date}}, {{pickup_time}}'],
      ['Return', '{{return_date}}, {{return_time}}'],
      ['Assigned to', '{{assigned_to}}'],
    ),
    button('Open the request', '@va_cs_booking'),
    small('Admins: if customer service cannot reach it, take it or reassign it from the same page.'),
  ],
  sample: { waiting_time: '2 hours 5 minutes', request_received_at: 'Tue, Oct 20 at 10:02 am', assigned_to: 'Nobody yet' },
};
