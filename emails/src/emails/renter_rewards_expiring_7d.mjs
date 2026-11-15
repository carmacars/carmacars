import { hero, p, button, small, facts } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_rewards_expiring_7d',
  audience: 'renter',
  category: 'transactional',
  from: FROM.hello,
  digest: false,
  trigger: 'CarmaCars Rewards notices (migration 3000, hourly job): 7 days before the renter\'s points end (12 months after the last rental or redemption by default), after the 30-day reminder (renter_rewards_expiring). Once per period of activity. Not sent when the reminder days are 7 or fewer. Switch: Admin > Settings > Rewards, Emails and notices (on by default).',
  timing: '7 days before the points end',
  subject: 'Last week to keep your {{points_balance}} CarmaCars points',
  preheader: 'They end on {{expiry_date}}.',
  ref: 'Rewards',
  body: [
    hero('Rewards', 'Your points end in 7 days', 'Hi {{first_name}}. Your {{points_balance}} points, worth {{points_value}}, end on {{expiry_date}}.'),
    facts(['Points', '{{points_balance}}'], ['Worth', '{{points_value}}'], ['They end on', '{{expiry_date}}']),
    p('A rental, or turning points into a code, keeps every point for another year.'),
    button('See my rewards', '{{rewards_url}}'),
    small('Points come off the rental charge only, never fees, add-ons, coverage, tax or the deposit.'),
  ],
  sample: { points_balance: '1,240', points_value: '$12.40', expiry_date: 'Mon, Dec 7, 2026', rewards_url: 'https://carmacars.ca/account/rewards' },
};
