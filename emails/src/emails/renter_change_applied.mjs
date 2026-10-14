import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_change_applied',
  audience: 'renter',
  category: 'transactional',
  from: FROM.bookings,
  digest: false,
  trigger: 'A change to a confirmed booking is applied: the renter accepted online (signed the amendment and any difference was charged), or an Admin recorded the renter\'s agreement by phone. Carries what changed, the money, and the signed amendment when there is one.',
  timing: 'Immediate',
  subject: 'Booking {{booking_number}} is updated',
  preheader: 'Here are your new booking details. Amendment {{amendment_number}}.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Booking updated', 'Your booking has the new details', 'Thanks, {{first_name}}. Here is what changed.'),
    compare('change_rows', 'Before', 'Now'),
    facts(
      ['Payment', '{{money_text}}'],
      ['Amendment', '{{amendment_number}}'],
    ),
    when('has_amendment_pdf', [
      p('Your signed amendment is kept with your booking: [open the PDF]({{signed_agreement_url}}).'),
    ]),
    button('View your booking', '@booking'),
    small('Everything else in your rental agreement stays the same. The file link works for {{link_expiry}}; the amendment is always in your account under Documents.'),
  ],
  sample: {
    change_rows: [
      { label: 'Return', before: 'Thu, Mar 11, 10:00 am', after: 'Fri, Mar 12, 10:00 am' },
      { label: 'Total with HST', before: '$468.95', after: '$581.95' },
    ],
    money_text: 'We charged $113.00 to your card ending 4242.', amendment_number: 'RA-10482-A1', has_amendment_pdf: true,
  },
};
