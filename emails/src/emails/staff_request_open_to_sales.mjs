import { hero, small, facts, notice, button, rows, when } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_request_open_to_sales',
  audience: 'staff_va_sales',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'A booking request from the website has had no reply for 30 minutes (program setting request_sales_after_minutes, 30 by default; r49, app.job_requests_open_to_sales) and is now open to Sales: the To do "A booking request is open to Sales" is raised with it. Only in business hours (8 am to 9 pm Toronto time); a request that waited overnight is told at 8 am. Once per request. At 2 hours with no reply customer service, Sales and the Admins get staff_request_waiting.',
  timing: '30 minutes after a request, business hours',
  subject: 'Open to Sales: request {{booking_number}}',
  preheader: '{{renter_name}}, {{vehicle_name}}, pickup {{pickup_date}}. Nobody has answered yet: take it.',
  ref: 'Request {{booking_number}}',
  body: [
    hero('Request open to Sales', 'Nobody has answered this request', '{{renter_name}} asked about the {{vehicle_name}} and has waited {{waiting_time}}. Whoever opens it first answers it.'),
    facts(
      ['Pickup', '{{pickup_date}}, {{pickup_time}}'],
      ['Return', '{{return_date}}, {{return_time}}'],
    ),
    button('Open the request', '@va_cs_booking'),
    small('It is also on your To do. If it still has no reply after 2 hours, customer service and the Admins are told.'),
  ],
  sample: { waiting_time: '30 minutes' },
};
