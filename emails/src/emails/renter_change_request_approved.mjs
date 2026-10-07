import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_change_request_approved',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'Staff approve a change request on a confirmed booking. Sent when the change request status becomes approved. (A change to a booking that is still offered is sent as a revised offer with renter_offer_ready instead.)',
  timing: 'Immediate',
  subject: 'Your change to booking {{booking_number}} is ready to accept',
  preheader: 'Review the new details and accept by {{accept_by}}.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Change available', 'We can make that change', 'Here is your booking with the change applied, {{first_name}}. It takes effect when you accept.'),
    compare('approved_changes', 'Before', 'After'),
    when('has_difference', [
      figure('{{difference_label}}', '{{difference_amount}}', 'HST included. New booking total: {{total_amount}}.'),
    ], [
      p('The price stays the same: **{{total_amount}}**.'),
    ]),
    button('Review and accept', '@booking_change'),
    p('Accept by **{{accept_by}}**. If the agreement changes, you sign the updated copy in the same step. If you do not accept, your booking stays as it was.'),
  ],
  sample: {
    approved_changes: [{ label: 'Return', before: 'Mon, Oct 26, 10:00 am', after: 'Tue, Oct 27, 10:00 am' }],
    has_difference: true,
    difference_label: 'Extra to pay',
    difference_amount: '$113.00',
    total_amount: '$581.95',
    accept_by: 'Thu, Oct 22 at 10:00 am',
  },
};
