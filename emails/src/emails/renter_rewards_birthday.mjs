import { hero, figure, button, small, list } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_rewards_birthday',
  audience: 'renter',
  category: 'marketing',
  from: FROM.hello,
  digest: false,
  trigger: 'CarmaCars Rewards notices (migration 3000, hourly job): 14 days before the renter\'s birthday (rewards_settings.birthday_notice_days), for a renter whose tier has a birthday reward switched on (Gold 10%, Platinum 15%, Black 20% by default). Once a year. Marketing: only while the renter has not unsubscribed. Switch: Admin > Settings > Rewards, Emails and notices (on by default).',
  timing: '14 days before the birthday',
  subject: 'Your birthday reward is waiting: {{reward_pct}} off',
  preheader: 'Pick up a car between {{window_from}} and {{window_to}}.',
  ref: 'Rewards',
  body: [
    hero('Happy birthday', 'A birthday reward for you, {{first_name}}', 'As a {{tier_name}} member, a rental that starts near your birthday costs {{reward_pct}} less.'),
    figure('Birthday reward', '{{reward_pct}} off', 'For a pickup from {{window_from}} to {{window_to}}.'),
    button('Choose a car', '@cars'),
    list('Sign in before you book: the price then shows the line Birthday reward.', 'It comes off the rental charge only, never fees, add-ons, coverage, tax or the deposit.', 'It does not add to a holiday reward: the bigger one applies.'),
    small('Not on bookings paid by an insurer. A car never goes below its lowest daily price.'),
  ],
  sample: { tier_name: 'Gold', reward_pct: '10%', window_from: 'Tue, Dec 1, 2026', window_to: 'Tue, Dec 15, 2026' },
};
