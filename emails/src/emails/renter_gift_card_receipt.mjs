import { hero, p, small, figure, facts, button, when } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_gift_card_receipt',
  audience: 'renter',
  category: 'transactional',
  from: FROM.billing,
  digest: false,
  trigger: 'Gift cards (migration 3600): a gift card or a gifted rental is paid by card on carmacars.ca/gift-cards. Sent to the buyer once per gift card. No HST is charged on a gift card: it is charged when the card pays for a rental.',
  timing: 'Immediate',
  subject: 'Your CarmaCars gift card receipt, {{gift_amount}}',
  preheader: 'For {{recipient_name}}. {{delivery_text}}',
  ref: 'Gift card ending {{gift_code_last4}}',
  body: [
    hero('Gift card', 'Thank you, {{first_name}}', 'Your gift for {{recipient_name}} is paid.'),
    figure('Paid', '{{gift_amount}}', 'Gift card ending {{gift_code_last4}}.'),
    facts(
      ['For', '{{recipient_name}}, {{recipient_email}}'],
      ['Delivery', '{{delivery_text}}'],
      ['Paid on', '{{payment_date}}'],
      ['Card', '{{card_text}}'],
    ),
    when('is_rental', [p('It is a gifted rental: {{rental_text}}. The amount waits in their account as a credit for that rental, or for any other CarmaCars rental they choose.')]),
    p('The balance never expires. It pays the rental, its fees and the HST. It never pays the refundable deposit, which is held on the driver\'s own card.'),
    button('See my gift cards', '@account_gift_cards'),
    small('No HST is charged on a gift card itself: HST is charged on the rental it pays for. Gift cards are not refundable for cash, except where the law requires it.'),
  ],
  sample: { gift_amount: '$150.00', recipient_name: 'Jordan Lee', recipient_email: 'jordan@example.test', delivery_text: 'Emailed on Fri, Dec 25, 2026', gift_code_last4: 'Q7XM', payment_date: 'Mon, Nov 23, 2026', card_text: 'Visa ending 4242', is_rental: true, rental_text: '3 days in the 2023 Toyota Corolla' },
};
