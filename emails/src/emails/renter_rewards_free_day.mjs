import { hero, figure, button, small, list } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_rewards_free_day',
  audience: 'renter',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'CarmaCars Rewards notices (migration 3000): the Black tier\'s free rental day code was made for the renter (2421, one a year). Once per code. Switch: Admin > Settings > Rewards, Emails and notices (on by default).',
  timing: 'When the free day code is made',
  subject: 'Your free rental day is ready',
  preheader: 'Code {{free_day_code}} is good until {{free_day_until}}.',
  ref: 'Rewards',
  body: [
    hero('Rewards', 'A free day on us, {{first_name}}', 'As a {{tier_name}} member you get one free rental day a year. It is ready to use.'),
    figure('Your code', '{{free_day_code}}', 'One free day, good until {{free_day_until}}.'),
    button('Book with my free day', '{{book_url}}'),
    list('The button opens a booking with the code already in the promo code box.', 'Or enter the code in the promo code box when you send your booking request.'),
    small('CarmaCars pays for the free day, not the car owner. The code is yours alone and works once.'),
  ],
  sample: { tier_name: 'Black', free_day_code: 'FREE7KQ4XM', free_day_until: 'Sun, Nov 14, 2027', book_url: 'https://carmacars.ca/book?promo=FREE7KQ4XM' },
};
