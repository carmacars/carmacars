import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_change_proposed',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Staff (customer service, Fleet or an Admin) propose a change to a confirmed booking: new pickup or return times, another car, or a new rental charge. Sent once the proposal is saved, unless the change was agreed by phone and applied at once. The booking stays as it is until the renter accepts by the deadline (Program settings: booking_change_accept_hours, never later than the pickup less booking_change_lead_hours).',
  timing: 'Immediate',
  subject: 'We suggest a change to booking {{booking_number}}',
  preheader: 'Review it and answer by {{accept_by}}. Your booking stays as it is until you accept.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Change suggested', 'A change to your booking', '{{change_reason}}'),
    compare('change_rows', 'Now', 'Suggested'),
    when('has_difference', [
      figure('{{difference_label}}', '{{difference_amount}}', 'HST included. New booking total: {{total_amount}}.'),
    ], [
      p('The price stays the same: **{{total_amount}}**.'),
    ]),
    button('Review and answer', '@booking_change'),
    p('Answer by **{{accept_by}}**. To accept, you sign a short amendment to your rental agreement on the same page{{#if has_difference}} and the difference is settled on your card on file{{/if}}. If you decline, or do not answer in time, your booking stays exactly as it is.'),
    small('Questions about this change? Reply to this email or call us.'),
  ],
  sample: {
    change_reason: 'The car you booked needs a short service on Thursday morning. We can keep you in it for one more day instead.',
    change_rows: [
      { label: 'Return', before: 'Thu, Mar 11, 10:00 am', after: 'Fri, Mar 12, 10:00 am' },
      { label: 'Total with HST', before: '$468.95', after: '$581.95' },
    ],
    has_difference: true, difference_label: 'Extra to pay', difference_amount: '$113.00', total_amount: '$581.95', accept_by: 'Mon, Mar 1 at 3:00 pm',
  },
};
