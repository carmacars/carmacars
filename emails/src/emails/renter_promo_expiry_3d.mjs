import { hero, figure, button, list } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_promo_expiry_3d',
  audience: 'renter',
  category: 'marketing',
  from: FROM.hello,
  digest: false,
  trigger: 'Promo code expiry (migration 0161): a discount code issued to a person (a come-back offer, a Live visitors code, a code made for one renter) has not been used and its last day is promo_reminder_3d_days days away (3 by default). Sent once per code, to the renter it was issued to, only while they have agreed to get offers and have not unsubscribed, never once the code is on a booking request, and only inside the sending hours. Discount game codes have their own transactional reminder (renter_game_code_reminder_3d).',
  timing: 'promo_reminder_3d_days (3) days before the last day of the code',
  subject: 'Your {{prize_label}} code ends in {{days_left}}',
  preheader: 'Code {{discount_code}} is good until {{discount_expires}}.',
  ref: 'Your offer',
  body: [
    hero('{{days_left}} left', 'Your code ends {{discount_expires}}', 'Hi {{first_name}}. Your {{prize_label}} code has not been used yet. Pick a car before it runs out.'),
    figure('Your code', '{{discount_code}}', '{{prize_label}} {{discount_applies_to}}.'),
    button('Choose a car', '@cars'),
    list(
      'Enter the code in the promo code box when you send your booking request.',
      '{{discount_terms}}',
    ),
  ],
  sample: {
    prize_label: '15% off', discount_code: 'BACK7KQ4XM', discount_expires: 'Thu, Dec 31, 2026',
    days_left: '3 days', discount_applies_to: 'the rental charge', discount_terms: 'Off the rental charge only, not fees, the Deposit or tax.',
  },
};
