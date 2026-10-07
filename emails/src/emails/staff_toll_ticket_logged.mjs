import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'staff_toll_ticket_logged',
  audience: 'staff_va_finance',
  category: 'transactional',
  from: FROM.billing,
  digest: true,
  digestSlot: 'next',
  trigger: 'A toll or ticket row is created (a notice is logged) and the automatic match has run. Queued for the next finance digest with the match result.',
  timing: 'Next digest',
  subject: '{{notice_type}} logged: plate {{vehicle_plate}}, {{notice_amount}}, due {{notice_due_date}}',
  preheader: 'Match: {{match_summary}}. Charge it within 3 business days.',
  ref: 'Notice {{notice_number}}',
  body: [
    hero('Toll or ticket', '{{notice_type}} logged for plate {{vehicle_plate}}', 'Match and charge it within 3 business days, and before the due date on the notice.'),
    facts(
      ['Notice', '{{notice_description}}, no. {{notice_number}}'],
      ['Date and time', '{{notice_event_date}}'],
      ['Amount', '{{notice_amount}}'],
      ['Due', '{{notice_due_date}}'],
      ['Match', '{{match_summary}}'],
    ),
    button('Open the notice', '@va_finance_toll'),
    list(
      '**Renter:** pay it, charge the amount plus the fee to the deposit if still held, otherwise the card on file. Send the notice copy.',
      '**Owner on an Owner Booking:** bill at cost, no fee.',
      '**Owner outside the program, or a Turo-Only car:** forward to the owner.',
      '**Staff:** CarmaCars pays. Log the staff member.',
    ),
  ],
  sample: {
    toll_ticket_id: 'tt-9012', notice_type: 'Toll invoice', notice_description: 'Highway 407 ETR', notice_number: '4471-0092',
    notice_event_date: 'Sat, Oct 24, 2026 at 3:18 pm', notice_amount: '$18.42', notice_due_date: 'Nov 20, 2026',
    match_summary: 'Booking CC-10482, Maya Okafor (renter)', vehicle_plate: 'CMCR 482',
  },
};
