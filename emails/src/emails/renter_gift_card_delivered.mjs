import { hero, p, small, figure, facts, button, link, notice, list, when } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_gift_card_delivered',
  audience: 'renter',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'Gift cards (migration 3600): a paid gift card or gifted rental reaches its send date (at once when no date was chosen), or an Admin issues a voucher credit to someone by email, or an Admin resends it. Sent to the recipient\'s email, once per gift card and send.',
  timing: 'On the send date chosen by the buyer, else immediate',
  subject: '{{from_name}} sent you a CarmaCars gift card',
  preheader: '{{gift_amount}} toward your next rental.',
  ref: 'Gift card ending {{gift_code_last4}}',
  body: [
    hero('Gift card', 'A gift for you, {{first_name}}', '{{from_name}} sent you {{gift_amount}} for a CarmaCars rental.'),
    when('has_message', [notice('info', 'A message from {{from_name}}', '{{gift_message}}')]),
    figure('Your code', '{{gift_code}}', '{{gift_amount}} to spend on CarmaCars rentals.'),
    when('is_rental', [p('It is a gifted rental: {{rental_text}}. Use it for that car, or for any other car you like.')]),
    facts(['Expires', '{{expiry_text}}']),
    button('Use my gift card', '{{redeem_url}}'),
    list('Sign in or create your account, then add the code under Gift cards. It is then yours alone.', 'When you sign and pay for a booking, the balance is used first. Anything left stays on the card for next time.', 'It pays the rental, its fees and the HST, never the refundable deposit.'),
    link('Print the gift card or save it as a PDF', '{{card_url}}'),
    small('Keep the code safe: anyone who has it can add it to their account until you do.'),
  ],
  sample: { from_name: 'Sam Rivera', gift_amount: '$150.00', has_message: true, gift_message: 'Happy birthday. Take a road trip on me.', gift_code: 'CCGC-7KQ4-XM2P-Q7XM', gift_code_last4: 'Q7XM', is_rental: false, rental_text: '', expiry_text: 'Never', redeem_url: 'https://carmacars.ca/account/gift-cards?code=CCGC-7KQ4-XM2P-Q7XM', card_url: 'https://carmacars.ca/gift-cards/card/0f3c9a1b2c3d4e5f60718293a4b5c6d7' },
};
