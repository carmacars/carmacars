import { hero, p, figure, facts, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_gift_card_refunded',
  audience: 'renter',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'Gift cards (migration 3600): an approved refund of a booking paid with a gift card returned the amount to the card balance. Sent to the card holder once per refund.',
  timing: 'Immediate',
  subject: '{{amount_returned}} is back on your gift card',
  preheader: 'From booking {{booking_number}}. Your balance is {{balance_left}}.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Gift card', 'Back on your gift card', 'The gift card part of the refund on booking {{booking_number}} is back on your card, {{first_name}}.'),
    figure('Returned', '{{amount_returned}}', 'Card ending {{gift_code_last4}}.'),
    facts(['Balance now', '{{balance_left}}'], ['Booking', '{{booking_number}}']),
    p('It is ready to use on your next booking. Any part you paid by card goes back to that card separately.'),
    button('See my gift cards', '@account_gift_cards'),
  ],
  sample: { amount_returned: '$75.00', balance_left: '$75.00', booking_number: 'CC-10482', gift_code_last4: 'Q7XM' },
};
