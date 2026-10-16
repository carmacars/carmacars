import { hero, p, small, h, rule, vehicle, keyfacts, figure, facts, price, compare, table, rows, button, link, notice, list, steps, when, each } from '../components.mjs';
import { FROM } from '../brand.mjs';
import { trip, places, bookingPrice } from '../snippets.mjs';

export default {
  code: 'renter_refund_issued',
  audience: 'renter',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'A refund row reaches status succeeded at the processor, for any refund except one already reported by a cancellation email sent in the same hour. Covers refunds for unused time after a breakdown, corrections and a charged deposit returned.',
  timing: 'Immediate',
  subject: 'Refund of {{refund_amount}} sent, booking {{booking_number}}',
  preheader: 'Back to your {{card_brand}} ending {{card_last4}}. Allow up to 10 business days.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Refund issued', 'Your refund is on its way', 'We sent a refund to the card you paid with, {{first_name}}.'),
    figure('Refunded', '{{refund_amount}}', 'To your {{card_brand}} ending {{card_last4}}.'),
    facts(
      ['Reason', '{{refund_reason}}'],
      ['Sent on', '{{payment_date}}'],
      ['Booking', '{{booking_number}}, {{vehicle_name}}'],
    ),
    p('Refunds arrive within {{refund_days}} business days. Your bank may take longer to show it. There is nothing you need to do.'),
    button('View my booking', '@booking'),
  ],
  sample: { refund_amount: '$113.00', refund_reason: 'Unused day after a breakdown that was not your fault', payment_date: 'Tue, Oct 27, 2026' },
};
