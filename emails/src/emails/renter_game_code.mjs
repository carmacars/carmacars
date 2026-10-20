import { hero, figure, button, list, small } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_game_code',
  audience: 'renter',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'A visitor plays a discount game on the site (spin the wheel, scratch to reveal, quick blackjack, cup shuffle or Plinko) and claims the prize with their first name and email. One email to that address with the single-use code. Transactional: it is the code they asked for, sent with or without marketing consent.',
  timing: 'Immediate',
  subject: 'Your CarmaCars code: {{prize_label}}',
  preheader: 'Code {{discount_code}}, good until {{discount_expires}}.',
  ref: 'Your prize',
  body: [
    hero('You won', '{{prize_label}} your rental', 'Nice play, {{first_name}}. Here is your code. Use it on any car before it runs out.'),
    figure('Your code', '{{discount_code}}', '{{prize_label}} {{discount_applies_to}}. Book by {{discount_expires}}.'),
    button('Choose a car', '@cars'),
    list(
      'Enter the code in the promo code box when you send your booking request.',
      'One use, on one booking. It cannot be combined with another promo code.',
      '{{discount_terms}}',
    ),
    small('Full terms: carmacars.ca/terms, section 14. Nothing is booked until you approve our offer, sign and pay.'),
  ],
  sample: {
    prize_label: '10% off', discount_code: 'WIN-7KQ4-XM2P', discount_expires: 'Mon, Oct 26, 2026',
    discount_applies_to: 'the rental charge, up to $75.00', discount_terms: 'Off the rental charge only, not fees, the Deposit or tax.',
  },
};
