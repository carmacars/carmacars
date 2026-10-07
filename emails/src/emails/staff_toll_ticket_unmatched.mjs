import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_toll_ticket_unmatched',
  audience: 'staff_va_finance',
  also: ['staff_admin'],
  category: 'transactional',
  from: FROM.billing,
  digest: true,
  digestSlot: 'morning',
  trigger: 'Daily check at 06:00: a toll or ticket row has had no match for 2 business days since it was logged. Queued for the morning digest of finance and the admins, once per notice.',
  timing: 'Morning digest, 2 business days after logging',
  subject: 'Unmatched for 2 business days: {{notice_type}}, plate {{vehicle_plate}}',
  preheader: '{{notice_amount}}, due {{notice_due_date}}. Nobody had the car on record.',
  ref: 'Notice {{notice_number}}',
  body: [
    hero('No match', 'This notice has no match after 2 business days', 'The plate, date and time do not fall inside any rental, Owner Booking or staff job on record.'),
    facts(
      ['Notice', '{{notice_description}}, no. {{notice_number}}'],
      ['Date and time', '{{notice_event_date}}'],
      ['Amount', '{{notice_amount}}'],
      ['Due', '{{notice_due_date}}'],
      ['Logged', '{{logged_at}}'],
      ['Nearest records', '{{nearest_records}}'],
    ),
    button('Open the notice', '@va_finance_toll'),
    small('Check the tracker history for that time. An admin decides who pays when there is no match. Do not let the due date pass.'),
  ],
  sample: {
    toll_ticket_id: 'tt-9044', notice_type: 'Parking ticket', notice_description: 'City of Toronto parking infraction', notice_number: 'PA 5521 1180',
    notice_event_date: 'Wed, Oct 28, 2026 at 7:55 am', notice_amount: '$75.00', notice_due_date: 'Nov 12, 2026', logged_at: 'Mon, Nov 2, 2026',
    nearest_records: 'Return job J-5530 ended Tue, Oct 27 at 6:10 pm', vehicle_plate: 'CMCR 482',
  },
};
