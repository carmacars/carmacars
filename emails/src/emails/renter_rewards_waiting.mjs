import { hero, p, button, small, facts, when } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_rewards_waiting',
  audience: 'renter',
  category: 'marketing',
  from: FROM.hello,
  digest: false,
  trigger: 'CarmaCars Rewards notices (migration 3000, hourly job): 30 days after the renter\'s last completed rental (rewards_settings.notice_waiting_days) with points or an unused free day, and no booking coming up. At most once in 60 days (notice_waiting_every_days). Marketing: only while the renter has not unsubscribed. Switch: Admin > Settings > Rewards, Emails and notices (on by default).',
  timing: '30 days after the last rental, at most every 60 days',
  subject: 'Your {{points_balance}} CarmaCars points are waiting',
  preheader: 'Worth {{points_value}} off your next rental.',
  ref: 'Rewards',
  body: [
    hero('Rewards', 'Your points are waiting, {{first_name}}', 'You have {{points_balance}} points, worth {{points_value}} off the rental charge of your next booking.'),
    facts(['Your points', '{{points_balance}}'], ['Worth', '{{points_value}}'], ['Your tier', '{{tier_name}}']),
    when('has_free_day', [p('Your free rental day is waiting too: code **{{free_day_code}}**, good until {{free_day_until}}.')]),
    button('Choose a car', '@cars'),
    small('Points come off the rental charge only, never fees, add-ons, coverage, tax or the deposit.'),
  ],
  sample: { points_balance: '1,240', points_value: '$12.40', tier_name: 'Gold', has_free_day: false, free_day_code: '', free_day_until: '' },
};
