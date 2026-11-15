import { hero, button, small, facts, table, when, p } from '../components.mjs';
import { FROM } from '../brand.mjs';

export default {
  code: 'renter_rewards_statement',
  audience: 'renter',
  category: 'marketing',
  from: FROM.hello,
  digest: false,
  trigger: 'CarmaCars Rewards notices (migration 3000, hourly job): on the 1st of each month from 9:00 Toronto time, the last month\'s points for each renter with a balance above 0 or points earned or used that month. Once per renter and month. Marketing: only while the renter has not unsubscribed. Switch: Admin > Settings > Rewards, Emails and notices (on by default).',
  timing: 'Monthly, on the 1st',
  subject: 'Your CarmaCars points for {{month_label}}',
  preheader: '{{points_balance}} points, worth {{points_value}}.',
  ref: '{{month_label}}',
  body: [
    hero('Rewards', 'Your points in {{month_label}}', 'Hi {{first_name}}, here is your CarmaCars Rewards month.'),
    facts(['Earned', '{{month_earned}}'], ['Used', '{{month_used}}'], ['Your points now', '{{points_balance}}'], ['Worth', '{{points_value}}'], ['Your tier', '{{tier_name}}']),
    when('has_entries', [table({ each: 'entries', cols: [{ head: 'Date', value: '{{date}}' }, { head: 'For', value: '{{reason}}' }, { head: 'Points', value: '{{points}}', align: 'right' }] })]),
    when('has_next_tier', [p('{{points_to_next}} more points earned in 12 months make you {{next_tier}}.')]),
    button('See my rewards', '{{rewards_url}}'),
    small('Points come off the rental charge only, never fees, add-ons, coverage, tax or the deposit.'),
  ],
  sample: {
    month_label: 'October 2026', month_earned: '650', month_used: '0', points_balance: '1,240', points_value: '$12.40', tier_name: 'Gold',
    has_entries: true, entries: [{ date: 'Mon, Oct 26, 2026', reason: 'Rental CC-10482', points: '+450' }, { date: 'Mon, Oct 26, 2026', reason: 'Damage-free rental CC-10482', points: '+200' }],
    has_next_tier: true, points_to_next: '13,760', next_tier: 'Platinum', rewards_url: 'https://carmacars.ca/account/rewards',
  },
};
