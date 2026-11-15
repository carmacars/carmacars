import { hero, figure, button, small, list } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_rewards_holiday',
  audience: 'renter',
  category: 'marketing',
  from: FROM.hello,
  digest: false,
  trigger: 'CarmaCars Rewards notices (migration 3000, hourly job): 10 days before a holiday weekend (rewards_settings.holiday_notice_days; the Ontario holidays in Admin > Settings > Rewards), for a renter whose tier has a holiday reward switched on (Gold 10%, Platinum 15%, Black 20% by default). Once per holiday. Marketing: only while the renter has not unsubscribed. Switch: Admin > Settings > Rewards, Emails and notices (on by default).',
  timing: '10 days before each holiday weekend',
  subject: '{{holiday_name}}: {{reward_pct}} off for you',
  preheader: 'Pick up a car between {{window_from}} and {{window_to}}.',
  ref: 'Rewards',
  body: [
    hero('Holiday reward', '{{holiday_name}} is coming, {{first_name}}', 'As a {{tier_name}} member, a rental that starts on the holiday weekend costs {{reward_pct}} less.'),
    figure('Holiday reward', '{{reward_pct}} off', 'For a pickup from {{window_from}} to {{window_to}}.'),
    button('Choose a car', '@cars'),
    list('Sign in before you book: the price then shows the line Holiday reward.', 'It comes off the rental charge only, never fees, add-ons, coverage, tax or the deposit.', 'It does not add to a birthday reward: the bigger one applies.'),
    small('Not on bookings paid by an insurer. A car never goes below its lowest daily price.'),
  ],
  sample: { holiday_name: 'Christmas', tier_name: 'Gold', reward_pct: '10%', window_from: 'Thu, Dec 24, 2026', window_to: 'Sat, Dec 26, 2026' },
};
