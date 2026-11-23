import { hero, p, figure, facts, button } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_gift_card_used',
  audience: 'renter',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'Gift cards (migration 3600): a booking paid with a gift card balance is confirmed. Sent to the card holder once per booking and card.',
  timing: 'Immediate',
  subject: '{{amount_used}} of your gift card paid booking {{booking_number}}',
  preheader: '{{balance_left}} is left on the card.',
  ref: 'Booking {{booking_number}}',
  body: [
    hero('Gift card', 'Your gift card paid', 'Your booking {{booking_number}} is paid in part or in full with your gift card, {{first_name}}.'),
    figure('Used', '{{amount_used}}', '{{balance_left}} left on the card ending {{gift_code_last4}}.'),
    facts(['Booking', '{{booking_number}}'], ['Balance left', '{{balance_left}}']),
    p('If the booking is cancelled or refunded, the gift card part goes back to the card balance.'),
    button('See my gift cards', '@account_gift_cards'),
  ],
  sample: { amount_used: '$150.00', balance_left: '$0.00', booking_number: 'CC-10482', gift_code_last4: 'Q7XM' },
};
