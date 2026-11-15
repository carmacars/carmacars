import { hero, figure, button, small } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_rewards_free_day_ending',
  audience: 'renter',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'CarmaCars Rewards notices (migration 3000, hourly job): the renter\'s free rental day code is unused and ends in 30 days, and again in 7 days. Once each. Switch: Admin > Settings > Rewards, Emails and notices (on by default).',
  timing: '30 and 7 days before the free day code ends',
  subject: 'Your free rental day ends in {{days_left}}',
  preheader: 'Code {{free_day_code}} is good until {{free_day_until}}.',
  ref: 'Rewards',
  body: [
    hero('Rewards', 'Use your free day before {{free_day_until}}', 'Hi {{first_name}}. Your free rental day has not been used yet.'),
    figure('Your code', '{{free_day_code}}', 'One free day, good until {{free_day_until}}.'),
    button('Book with my free day', '{{book_url}}'),
    small('The button opens a booking with the code already in the promo code box.'),
  ],
  sample: { days_left: '7 days', free_day_code: 'FREE7KQ4XM', free_day_until: 'Sun, Nov 21, 2026', book_url: 'https://carmacars.ca/book?promo=FREE7KQ4XM' },
};
