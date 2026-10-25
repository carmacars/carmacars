import { hero, figure, button, list } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_game_code_reminder_3d',
  audience: 'renter',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'Promo code expiry (migration 0161): a code won in a discount game on the site has not been used and its last day is promo_reminder_3d_days days away (3 by default). Sent once per code, to the address that claimed it. Transactional: a reminder of the code they asked for, like the day-before reminder (renter_game_code_reminder). Not sent once the code is on a booking request.',
  timing: 'promo_reminder_3d_days (3) days before the last day of the code',
  subject: 'Your {{prize_label}} code ends in {{days_left}}',
  preheader: 'Code {{discount_code}} is good until {{discount_expires}}.',
  ref: 'Your prize',
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
    prize_label: '10% off', discount_code: 'WIN-7KQ4-XM2P', discount_expires: 'Mon, Oct 26, 2026',
    days_left: '3 days', discount_applies_to: 'the rental charge, up to $75.00', discount_terms: 'Off the rental charge only, not fees, the Deposit or tax.',
  },
};
